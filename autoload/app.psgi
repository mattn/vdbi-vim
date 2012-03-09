#!perl

use strict;
use warnings;
use utf8;
use DBI;
use Encode qw/decode_utf8/;
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
          $data_source =~ /^dbi:oracle:/i ? {ora_charset => 'AL32UTF8'} :
          $data_source =~ /^dbi:sqlite:/i ? {sqlite_unicode => 1} :
          $data_source =~ /^dbi:pg:/i     ? {pg_enable_utf8 => 1} :
          $data_source =~ /^dbi:mysql:/i  ? {mysql_enable_utf8 => 1, RaiseError => 1} :
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

my $webui = do { local $/; <DATA> };

my $app = sub {
    my $env = shift;
    my $req = Plack::Request->new($env);
    unless ($ENV{VDBI_PUBLIC} or $req->address eq '127.0.0.1') {
        return [403, [], ["Forbidden"]];
    }
    if ($req->path_info eq '/shutdown') {
        $methods{'disconnect'}->();
        # TODO: does not work
        #$env->{'psgix.harakiri'} = 1;
        kill 'KILL', $$;
        return [ 200, [ 'Content-Type', 'text/plain' ], [ 'OK' ] ];
    }
    if ($req->method eq 'POST') {
        my $json = from_json(decode_utf8 $req->content);
        my $id = $json->{id} || '';
        my $method = $json->{method} || '';
        my $params = $json->{params} || [];
        my $code = $methods{$method} or return [404, [], ["not found: $method"]];
        my $result = eval { $code->(@{$params}) };
        my $resp = to_json({
            id => $id,
            error => $@ ? $@ : undef,
            result => $result,
        });
        utf8::encode($resp) if utf8::is_utf8($resp) && $resp =~ /[^\x00-\x7f]/;
        return [ 200, [ 'Content-Type', 'text/json' ], [ $resp ] ];
    }
    return [ 200, [ 'Content-Type', 'text/html' ], [ $webui ] ];
};

builder {
    enable 'ContentLength';
    $app;
};

__DATA__
<!doctype html>
<html>
<head>
<meta charset="utf-8">
<script src="http://ajax.googleapis.com/ajax/libs/jquery/1.7/jquery.min.js"></script>
<script src="https://raw.github.com/hagino3000/jquery-jsonrpc2.0/master/jquery.jsonrpc.js"></script>
<script>
$(function() {
  $('#connect').click(function() {
    $.jsonrpc({
      url: "/",
      method: "connect",
      params: [
        $('#datasource').val(),
        $('#username').val(),
        $('#password').val()
      ]
    }, {
      fault: function(error) { alert(error) },
      success: function(resp) {
        $('#config input').attr('disabled', 'disabled');
        $('#query-editor').removeAttr('disabled');
        $('#run').removeAttr('disabled');
      }
    })
  });
  $('#run').click(function() {
    $.jsonrpc({ url: "/", method: "prepare", params: [ $('#query-editor').val() ] }, {
      fault: function(error) { alert(JSON.stringify(error)) },
      success: function(resp) {
        $.jsonrpc({ url: "/", method: "execute", params: [] }, {
          fault: function(error) { alert(JSON.stringify(error)) },
          success: function(resp) {
            $.jsonrpc({ url: "/", method: "fetch_columns", params: [] }, {
              fault: function(error) { alert(JSON.stringify(error)) },
              success: function(columns) {
                $.jsonrpc({ url: "/", method: "fetch", params: [-1] }, {
                  fault: function(error) { alert(error) },
                  success: function(rows) {
                    $('#result tr').remove();
                    var header = $('<tr />').appendTo('#result tbody');
                    $.each(columns, function(n, e) { $(header).append($('<th />').text(e)); });
                    $.each(rows, function(n, row) {
                      var result = $('<tr />').appendTo('#result tbody');
                      $.each(row, function(n, col) { $(result).append($('<td />').text(col)); });
                    });
                  }
                })
              }
            })
          }
        })
      }
    })
  });
})
</script>
<style>
.config-label { display:block; floet:left; width:200px; }
#result { border: 1px #e3e3e3 solid; border-collapse: collapse; border-spacing: 0; }
#result th { padding: 5px; border: #e3e3e3 solid; border-width: 0 0 1px 1px; background: #f5f5f5; font-weight: bold; line-height: 120%; text-align: center; }
#result td { padding: 5px; border: 1px #e3e3e3 solid; border-width: 0 0 1px 1px; text-align: center; }
</style>
</head>
<body>
<div id="config">
<label class="config-label" for="datasource">Datasource:</label><input id="datasource" type="text" value="dbi:SQLite:dbname=./foo.db" /><br />
<label class="config-label" for="username">Username:</label><input id="username" type="text" value="" /><br />
<label class="config-label" for="password">Password:</label><input id="password" type="password" value="" /><br />
<input type="button" id="connect" value="Connect" />
</div>
<div id="query">
<textarea id="query-editor" disabled="disabled"></textarea><br />
<input type="button" id="run" value="Run" disabled="disabled" />
<table id="result"><tbody></tbody></table>
</div>
</body>
</html>
