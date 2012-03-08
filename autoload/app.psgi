#!perl

use strict;
use warnings;
use utf8;
use DBI;
use Plack::Request;
use Plack::Builder;
use RPC::XML;
use RPC::XML::ParserFactory;

our $dbh = undef;
our $sth = undef;

my %methods = (
    'connect' => sub {
        my ($data_source, $username, $auth) = map { $_->value } @_;
        if ($dbh) {
            eval { $dbh->disconnect(); }
        }
        my $opt = $data_source =~ /^dbi:Oracle:/ ? {ora_charset => 'AL32UTF8'} : undef;
        our $dbh = DBI->connect($data_source, $username, $auth, $opt);
        return $dbh->get_info(18);
    },
    'do' => sub {
        return undef unless $dbh;
        my ($sql, $params) = map { $_->value } @_;
        my $rows = $dbh->do($sql, undef, @$params);
        return $rows;
    },
    'select_all' => sub {
        return undef unless $dbh;
        my ($sql, $params) = map { $_->value } @_;
        my $rows = $dbh->selectall_arrayref($sql, undef, @$params);
        return $rows;
    },
    'prepare' => sub {
        return undef unless $dbh;
        $sth->finish() if $sth;
        my ($sql) = map { $_->value } @_;
        our $sth = $dbh->prepare($sql) or return undef;
        return 'sth';
    },
    'execute' => sub {
        return undef unless $sth;
        my ($params) = map { $_->value } @_;
        return $sth->execute(@$params) or return undef;
    },
    'fetch_columns' => sub {
        return undef unless $sth;
        return $sth->{NAME};
    },
    'fetch' => sub {
        return undef unless $sth;
        my ($num) = map { $_->value } @_;
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
        my ($flag) = map { $_->value } @_;
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
        my ($catalog, $schema, $table, $type) = map { $_->value } @_;
        $sth = $dbh->table_info( $catalog, $schema, $table, $type );
        return [$sth->{NAME}, grep { $_ } $sth->fetchall_arrayref()];
    },
    'column_info' => sub {
        return undef unless $dbh;
        eval {
            $sth->finish() if $sth;
        };
        my ($catalog, $schema, $table, $column) = map { $_->value } @_;
        $sth = $dbh->column_info( $catalog, $schema, $table, $column );
        return [[],[]] unless $sth;
        return [$sth->{NAME}, $sth->fetchall_arrayref()];
    },
    'primary_key_info' => sub {
        return undef unless $dbh;
        eval {
            $sth->finish() if $sth;
        };
        my ($catalog, $schema, $table) = map { $_->value } @_;
        $sth = $dbh->primary_key_info( $catalog, $schema, $table );
        return undef unless $sth;
        return [$sth->{NAME}, $sth->fetchall_arrayref()];
    },
    'foreign_key_info' => sub {
        return undef unless $dbh;
        eval {
            $sth->finish() if $sth;
        };
        my ($pkcatalog, $pkschema, $pktable, $fkcatalog, $fkschema, $fktable)
            = map { $_->value } @_;
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
        $env->{'psgix.harakiri'} = 1;
        return [ 200, [ 'Content-Type', 'text/plain' ], [ 'OK' ] ];
    }
    local $RPC::XML::ALLOW_NIL = 1;
    local $RPC::XML::ENCODING = 'utf-8';
    my $q = RPC::XML::ParserFactory->new()->parse($req->content);
    my $method_name = $q->name;
    my $code = $methods{$method_name} or return [404, [], ["not found: $method_name"]];
    my $rpc_res = RPC::XML::response->new($code->(@{$q->args}));
    my $resp = $rpc_res->as_string;
    utf8::encode($resp) if utf8::is_utf8($resp) && $resp =~ /[^\x00-\x7f]/;
    return [ 200, [ 'Content-Type', 'text/xml' ], [ $resp ] ];
};

builder {
    enable 'ContentLength';
    $app;
};
