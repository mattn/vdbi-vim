#!perl

use strict;
use warnings;
use utf8;
use DBI;
use JSON;
use Plack::Request;
use Plack::Builder;

our $dbh = undef;
our $sth = undef;

my %methods = (
    'connect' => sub {
        my ($data_source, $username, $auth) = @_;
        if ($dbh) {
            eval { $dbh->disconnect(); }
        }
        my $opt =
          $data_source =~ /^dbi:Oracle:/ ? {ora_charset => 'AL32UTF8'} :
          $data_source =~ /^dbi:SQLite:/ ? {sqlite_unicode => 1} :
          undef;
        our $dbh = DBI->connect($data_source, $username, $auth, $opt);
        return $dbh->get_info(18);
    },
    'do' => sub {
        return undef unless $dbh;
        my ($sql, $params) = @_;
        my $rows = $dbh->do($sql, undef, @$params);
        return $rows;
    },
    'select_all' => sub {
        return undef unless $dbh;
        my ($sql, $params) = @_;
        my $rows = $dbh->selectall_arrayref($sql, undef, @$params);
        return $rows;
    },
    'prepare' => sub {
        return undef unless $dbh;
        $sth->finish() if $sth;
        my ($sql) = @_;
        our $sth = $dbh->prepare($sql) or die $dbh->errstr;
        return 'sth';
    },
    'execute' => sub {
        return undef unless $sth;
        my ($params) = @_;
        return $sth->execute(@$params) or return undef;
    },
    'fetch_columns' => sub {
        return undef unless $sth;
        return $sth->{NAME};
    },
    'fetch' => sub {
        return undef unless $sth;
        my ($num) = @_;
        if (!defined($num) || $num eq -1) {
            return $sth->fetchall_arrayref();
        } else {
            my $ret = [];
            for (my $i = 0; $i < $num; $i++) {
                my $row = $sth->fetchrow_arrayref();
                last if $row eq undef;
                push @$ret, $row;
            }
            return $ret;
        }
    },
    'auto_commit' => sub {
        return undef unless $dbh;
        my ($flag) = @_;
        if ($flag eq "true") {
            $dbh->{AutoCommit} = 1;
            return 1;
        } else {
            $dbh->{AutoCommit} = 0;
            return 0;
        }
    },
    'commit' => sub {
        return undef unless $dbh;
        $dbh->commit();
        return 1;
    },
    'rollback' => sub {
        return undef unless $dbh;
        $dbh->rollback();
        return 1;
    },
    'disconnect' => sub {
        return undef unless $dbh;
        $dbh->disconnect();
        return 1;
    },
    'status' => sub {
        return undef unless $dbh;
        return [$dbh->err, $dbh->errstr, $dbh->state];
    },
    'type_info_all' => sub {
        return undef unless $dbh;
        return $dbh->type_info_all || [];
    },
    'type_info' => sub {
        return undef unless $dbh;
        return $dbh->type_info() || [];
    },
    'table_info' => sub {
        return undef unless $dbh;
        eval {
            $sth->finish() if $sth;
        };
        my ($catalog, $schema, $table, $type) = @_;
        $sth = $dbh->table_info( $catalog, $schema, $table, $type );
        return [$sth->{NAME}, grep { $_ } $sth->fetchall_arrayref()];
    },
    'column_info' => sub {
        return undef unless $dbh;
        eval {
            $sth->finish() if $sth;
        };
        my ($catalog, $schema, $table, $column) = @_;
        $sth = $dbh->column_info( $catalog, $schema, $table, $column );
        return [[],[]] unless $sth;
        return [$sth->{NAME}, $sth->fetchall_arrayref()];
    },
    'primary_key_info' => sub {
        return undef unless $dbh;
        eval {
            $sth->finish() if $sth;
        };
        my ($catalog, $schema, $table) = @_;
        $sth = $dbh->primary_key_info( $catalog, $schema, $table );
        return undef unless $sth;
        return [$sth->{NAME}, $sth->fetchall_arrayref()];
    },
    'foreign_key_info' => sub {
        return undef unless $dbh;
        eval {
            $sth->finish() if $sth;
        };
        my ($pkcatalog, $pkschema, $pktable, $fkcatalog, $fkschema, $fktable) = @_;
        $sth = $dbh->foreign_key_info( $pkcatalog, $pkschema, $pktable,
                                       $fkcatalog, $fkschema, $fktable );
        return undef unless $sth;
        return [$sth->{NAME}, $sth->fetchall_arrayref()];
    },
);

my $app = sub {
    my $env = shift;
    my $req = Plack::Request->new($env);
    if ($req->path_info eq '/shutdown') {
        $methods{'disconnect'}->();
        # TODO: does not work
        #$env->{'psgix.harakiri'} = 1;
        kill 'KILL', $$;
        return [ 200, [ 'Content-Type', 'text/plain' ], [ 'OK' ] ];
    }
    my $json = from_json($req->content);
    my $id = $json->{id} || '';
    my $method = $json->{method} || '';
    my $params = $json->{params} || [];
    my $code = $methods{$method} or return [404, [], ["not found: $method"]];
    my $result = eval { $code->(@{$params}) };
    my $resp = to_json({
        id => $id,
        error => $@,
        result => $result,
    });
    utf8::encode($resp) if utf8::is_utf8($resp) && $resp =~ /[^\x00-\x7f]/;
    return [ 200, [ 'Content-Type', 'text/json' ], [ $resp ] ];
};

builder {
    enable 'ContentLength';
    $app;
};
