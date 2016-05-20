#!/usr/bin/env perl
use warnings;
use strict;

use Carp qw(confess);
use Data::Dumper;
use Getopt::Long;
use Hash::Util qw(lock_hash);
use Mojolicious::Lite;
use YAML qw(LoadFile);

use lib 'lib';

use Ravada;
use Ravada::Auth;
use Ravada::Request;

my $help;
my $FILE_CONFIG = "/etc/ravada.conf";

GetOptions(
     'config=s' => \$FILE_CONFIG
         ,help  => \$help
     ) or exit;

if ($help) {
    print "$0 [--help] [--config=$FILE_CONFIG]\n";
    exit;
}

our $RAVADA = Ravada->new(config => $FILE_CONFIG);
our $TIMEOUT = 10;

init();
############################################################################3

any '/' => sub {
    my $c = shift;

    return quick_start($c);
};

any '/login' => sub {
    my $c = shift;
    return login($c);
};

any '/logout' => sub {
    my $c = shift;
    $c->session(expires => 1);
    $c->session(login => undef);
    $c->redirect_to('/');
};

###################################################

sub _logged_in {
    my $c = shift;

    $c->stash(_logged_in => $c->session('login'));
    return 1 if $c->session('login');
}


sub login {
    my $c = shift;

    return quick_start($c)    if _logged_in($c);

    my $login = $c->param('login');
    my $password = $c->param('password');
    my @error =();
    if ($c->param('submit') && $login) {
        push @error,("Empty login name")  if !length $login;
        push @error,("Empty password")  if !length $password;
    }

    if ( $login && $password ) {
        if (Ravada::Auth::login($login, $password)) {
            $c->session('login' => $login);
            return quick_start($c);
        } else {
            push @error,("Access denied");
        }
    }
    $c->render(
                    template => 'bootstrap/login' 
                      ,login => $login 
                      ,error => \@error
    );

}

sub quick_start {
    my $c = shift;

    _logged_in($c);

    my $login = $c->param('login');
    my $password = $c->param('password');
    my $id_base = $c->param('id_base');

    my @error =();
    if ($c->param('submit') && $login) {
        push @error,("Empty login name")  if !length $login;
        push @error,("Empty password")  if !length $password;
    }

    if ( $login && $password ) {
        if (Ravada::Auth::login($login, $password)) {
            $c->session('login' => $login);
        } else {
            push @error,("Access denied");
        }
    }
    return show_link($c, $id_base, ( $login or $c->session('login')))
        if $c->param('submit') && _logged_in($c) && defined $id_base;

    $c->render(
                    template => 'bootstrap/start' 
                    ,id_base => $id_base
                      ,login => $login 
                      ,error => \@error
                       ,base => list_bases()
    );
}

get '/ip' => sub {
    my $c = shift;
    $c->render(template => 'bases', base => list_bases());
};

get '/ip/*' => sub {
    my $c = shift;
    _logged_in($c);
    my ($base_name) = $c->req->url->to_abs =~ m{/ip/(.*)};
    my $ip = $c->tx->remote_address();
    my $base = $RAVADA->search_domain($base_name);
    show_link($c,$base,$ip);
};

any '/bases' => sub {
    my $c = shift;

    return access_denied($c) if !_logged_in($c);
    return new_base($c);
};

#######################################################

sub new_base {
    my $c = shift;
    my @error = ();
    my $ram = ($c->param('ram') or 2);
    my $disk = ($c->param('disk') or 8);
    if ($c->param('submit')) {
        push @error,("Name is mandatory")   if !$c->param('name');
        return req_new_base($c) if !@error;
    }
    $c->render(template => 'bootstrap/new_base'
                    ,name => $c->param('name')
                    ,ram => $ram
                    ,disk => $disk
                    ,image => _list_images()
                    ,error => \@error
    );
};

sub req_new_base {
    my $c = shift;
    my $req = Ravada::Request->create_domain(
           name => $c->param('name')
        ,id_iso => $c->param('id_iso')
    );

    my ($uri,$error) = wait_req_up($req);
    if ($uri) {
       $c->redirect_to($uri);
       $c->render(template => 'bootstrap/run', url => $uri , name => $c->param('name')
                ,login => $c->session('login'));

    } else {
        $c->render(template => 'fail', name => $c->param('name'), error => $error);
    }
}

sub _search_req_base_error {
    my $name = shift;
}
sub access_denied {
    my $c = shift;
    $c->render(data => "Access denied");
}

sub base_id {
    my $name = shift;
    my $base = $RAVADA->search_domain($name);

    return $base->id;
}

sub find_uri {
    my $host = shift;
    my $url = `virsh domdisplay $host`;
    warn $url;
    chomp $url;
    return $url;
}

sub provision {
    my $c = shift;
    my $id_base = shift;
    my $name = shift;

    die "Missing id_base "  if !defined $id_base;
    die "Missing name "     if !defined $name;

    my $domain = $RAVADA->search_domain(name => $name);
    return $domain if $domain;

    my $req = Ravada::Request->create_domain(name => $name, id_base => $id_base);
    wait_request_done($c,$req);

    $domain = $RAVADA->search_domain($name);

    if ( $req->error ) {
        $c->stash(error => $req->error) 
    } else {
        $c->stash(error => "I dunno why but no domain $name");
    }
    return $domain;
}

sub wait_request_done {
    my ($c, $req) = @_;
    
    for ( 1 .. $TIMEOUT ) {
        warn $req->status;
        last if $req->status eq 'done';
        sleep 1;
    }
    return $req;
}

sub show_link {
    my $c = shift;
    my ($base, $name) = @_;

    confess "Missing base" if !$base;
    confess "Missing name" if !$name;

    if(!ref $base) {
        $base = $RAVADA->search_domain_by_id($base) or die "I can't find base $base";
    }

    my $host = $base->name."-".$name;

    my $domain =( $RAVADA->search_domain($host)
            or provision($c, $base->id, $host));

    my $uri = $domain->display() if $domain;
    if (!$uri) {
        $c->render(template => 'fail', name => $host);
        return;
    }
    $c->redirect_to($uri);
    $c->render(template => 'bootstrap/run', url => $uri , name => $name
                ,login => $c->session('login'));
}

sub list_bases {
    my @bases = $RAVADA->list_bases();

    my %base;
    for my $base ( $RAVADA->list_bases ) {
        $base{$base->id} = $base->name;
    }
    return \%base;
}

sub _list_images {
    my $dbh = $RAVADA::CONNECTOR->dbh();
    my $sth = $dbh->prepare(
        "SELECT * FROM iso_images"
        ." ORDER BY name"
    );
    $sth->execute;
    my %image;
    while ( my $row = $sth->fetchrow_hashref) {
        $image{$row->{id}} = $row;
    }
    $sth->finish;
    lock_hash(%image);
    return \%image;
}

sub check_back_running {
    #TODO;
    return 1;
}

sub init {
    check_back_running() or warn "CRITICAL: rvd_back is not running\n";
}

app->start;
__DATA__

@@ index.html.ep
% layout 'default';
<h1>Welcome to SPICE !</h1>

<form method="post">
    User Name: <input name="login" value ="<%= $login %>" 
            type="text"><br/>
    Password: <input type="password" name="password" value=""><br/>
    Base: <select name="id_base">
%       for my $option (sort keys %$base) {
            <option value="<%= $option %>"><%= $base->{$option} %></option>
%       }
    </select><br/>
    
    <input type="submit" name="submit" value="launch">
</form>
% if (scalar @$error) {
        <ul>
%       for my $i (@$error) {
            <li><%= $i %></li>
%       }
        </ul>
% }

@@ bases.html.ep
% layout 'default';
<h1>Choose a base</h1>

<ul>
% for my $i (sort values %$base) {
    <li><a href="/ip/<%= $i %>"><%= $i %></a></li>
% }
</ul>

@@ run.html.ep
% layout 'default';
<h1>Run</h1>

Hi <%= $name %>, 
<a href="<%= $url %>">click here</a>

@@ fail.html.ep
% layout 'default';
<h1>Fail</h1>

Sorry <%= $name %>, I couldn't make it.
<pre>ERROR: <%= $error %></pre>

@@ layouts/default.html.ep
<!DOCTYPE html>
<html>
  <head><title><%= title %></title></head>
  <body>
    <%= content %>
    <hr>
        <h2>Requirements</h1>
            <ul>
            <li>Linux: virt-viewer</li>
            <li>Windows: <a href="http://bfy.tw/5Nur">Spice plugin for Firefox</a></li>
            </ul>
        </h2>
  </body>
</html>
