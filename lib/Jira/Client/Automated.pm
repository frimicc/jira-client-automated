use strict;
use warnings;
package Jira::Client::Automated;

our $VERSION = 1.0;

=head1 NAME

JIRA::Client::Automated

=head1 VERSION

version $VERSION

=head1 SYNOPSIS

    use JIRA::Client::Automated;

    my $jira = JIRA::Client::Automated->new($url, $user, $password);
    my $issue = $jira->create_issue($project, $type, $summary, $description);
    my @issues = $jira->search_issues($jql); # query should be a single string of JQL
    my $issue = $jira->get_issue($key);
    $jira->update_issue($key, $update_hash); # update_hash is { field => value, ... }
    $jira->create_comment($key, $text);
    $jira->attach_file_to_issue($key, $filename);
    $jira->transition_issue($key, $transition, $transition_hash); # transition_hash is { field => value, ... }
    $jira->close_issue($key, $resolve, $message); # resolve is the resolution value
    $jira->delete_issue($key);

=head1 DESCRIPTION

JIRA::Client::Automated is an adapter between any automated system and JIRA's REST API. This module is explicitly designed to easily create and close issues within a JIRA instance via automated scripts. 

For example, if you run nightly batch jobs, you can use JIRA::Client::Automated to have those jobs automatically create issues in JIRA for you when the script runs into errors. You can attach error log files to the issues and then they'll be waiting in someone's open issues list when they arrive at work the next day.

If you want to avoid creating the same issue more than once you can search JIRA for it first, only creating it if it doesn't exist. If it does already exist you can add a comment or a new error log to that issue.

=head1 WORKING WITH JIRA

Atlassian has made a very complete REST API for recent (> 5.0) versions of JIRA. By virtue of being complete it is also somewhat large and a little complex for the beginner. Reading their tutorials is *highly* recommended before you start making hashes to update or transition issues. 

https://developer.atlassian.com/display/JIRADEV/JIRA+REST+APIs

This module is designed for the JIRA 5.2.11 REST API, as of March 2013, but it seems to work fine with JIRA 6.0 as well. Your mileage may vary with future versions.

=head1 METHODS

=cut

use JSON;
use LWP::UserAgent;
use HTTP::Request;
use HTTP::Request::Common qw(GET POST PUT);

sub new {
    my ($class, $url, $user, $password) = @_;

    unless (defined $url && $url && defined $user && $user && defined $password && $password) {
        die "Need to specify url, username, and password to access JIRA.";
    }

    unless ($url =~ m{/$}) {
        $url .= '/';
    }

    # make sure we have a usable API URL
    my $auth_url = $url;
    unless ($auth_url =~ m{/rest/api/}) {
        $auth_url .= '/rest/api/latest/';
    }
    unless ($auth_url =~ m{/$}) {
        $auth_url .= '/';
    }
    $auth_url =~ s{//}{/}g;
    $auth_url =~ s{:/}{://};

    # authentication is screwy, so we need to use the in-url version
    $auth_url =~ s|^http(s)?://|http$1://${user}:${password}\@|;

    my $self = { url => $url, auth_url => $auth_url, };
    bless $self, $class;

    # cached UserAgent for talking to JIRA
    $self->{_ua} = LWP::UserAgent->new();

    # cached JSON object for handling conversions
    $self->{_json} = JSON->new->utf8();

    return $self;
}

sub create_issue {
    my ($self, $project, $type, $summary, $description) = @_;

    my $issue = {
        fields => {
            summary     => $summary,
            description => $description,
            issuetype   => { name => $type, },
            project     => { key => $project, } } };

    my $issue_json = $self->{_json}->encode($issue);
    my $uri        = "$self->{auth_url}issue/";

    my $request = POST $uri,
      Content_Type => 'application/json',
      Content      => $issue_json;
    my $response = $self->{_ua}->request($request);

    if (!$response->is_success()) {
        die "Error creating new JIRA issue $summary " . $response->status_line();
    }

    my $new_issue = $self->{_json}->decode($response->decoded_content());

    return $new_issue;
}

sub update_issue {
    my ($self, $key, $update_hash) = @_;

    my $issue = { fields => $update_hash };

    my $issue_json = $self->{_json}->encode($issue);
    my $uri        = "$self->{auth_url}issue/$key";

    my $request = PUT $uri,
      Content_Type => 'application/json',
      Content      => $issue_json;
    my $response = $self->{_ua}->request($request);

    if (!$response->is_success()) {
        die "Error updating JIRA issue $key " . $response->status_line();
    }

    return;
}

sub get_issue {
    my ($self, $key) = @_;
    my $uri = "$self->{auth_url}issue/$key";

    my $request = GET $uri, Content_Type => 'application/json';
    my $response = $self->{_ua}->request($request);

    if (!$response->is_success()) {
        die "Error getting JIRA issue $key " . $response->status_line();
    }

    my $new_issue = $self->{_json}->decode($response->decoded_content());

    return $new_issue;
}

# Each issue could have a different workflow and therefore a different transition id for 'Close Issue', so we
# have to look it up every time.
sub _get_transition_id {
    my ($self, $key, $t_name) = @_;
    my $uri = "$self->{auth_url}issue/$key/transitions";

    my $request = GET $uri, Content_Type => 'application/json';
    my $response = $self->{_ua}->request($request);

    if (!$response->is_success()) {
        die "Error getting available transitions for JIRA issue $key " . $response->status_line();
    }

    my $t_list = $self->{_json}->decode($response->decoded_content());
    my ($t_id);
    for my $transition (@{ $$t_list{transitions} }) {
        if ($$transition{name} eq $t_name) {
            $t_id = $$transition{id};
        }
    }

    return $t_id;
}

sub transition_issue {
    my ($self, $key, $t_name, $t_hash) = @_;

    my $t_id = $self->_get_transition_id($key, $t_name);
    $$t_hash{transition} = { id => $t_id };

    my $t_json = $self->{_json}->encode($t_hash);
    my $uri    = "$self->{auth_url}issue/$key/transitions";

    my $request = POST $uri,
      Content_Type => 'application/json',
      Content      => $t_json;

    my $response = $self->{_ua}->request($request);

    if (!$response->is_success()) {
        die "Error with $t_name for JIRA issue $key: " . $response->status_line();
    }

    return;
}

sub close_issue {
    my ($self, $key, $resolve, $comment) = @_;

    $comment //= 'Issue closed by script';

    my ($closing);
    if ($resolve) {
        $closing = {
            update => { comment => [{ add => { body => $comment }, }] },
            fields => { resolution => { name => $resolve } },
        };
    } else {
        $closing = {
            update => { comment  => [{ add => { body => $comment }, }] },
        };
    }

    return $self->transition_issue($key, 'Close Issue', $closing);
}

sub delete_issue {
    my ($self, $key) = @_;

    my $uri        = "$self->{auth_url}issue/$key";

    my $request = DELETE $uri;
    my $response = $self->{_ua}->request($request);

    if (!$response->is_success()) {
        die "Error deleting JIRA issue $key " . $response->status_line();
    }

    return;
}

sub create_comment {
    my ($self, $key, $text) = @_;

    my $comment = { body => $text };

    my $comment_json = $self->{_json}->encode($comment);
    my $uri          = "$self->{auth_url}issue/$key/comment";

    my $request = POST $uri,
      Content_Type => 'application/json',
      Content      => $comment_json;
    my $response = $self->{_ua}->request($request);

    if (!$response->is_success()) {
        die "Error creating new JIRA comment for $key : $text " . $response->status_line();
    }

    my $new_comment = $self->{_json}->decode($response->decoded_content());

    return $new_comment;

}

# This is a paged method. You pass in the starting number and max to retrieve and it returns those and the total
# number of hits. To get the next page, call search_issues() again with the start value = start + max, until total
# < max
# Note: if $max is > 1000 (set by jira.search.views.default.max in
# http://jira.example.com/secure/admin/ViewSystemInfo.jspa) then it'll be truncated to 1000 anyway.
sub search_issues {
    my ($self, $jql, $start, $max) = @_;

    my $query = {
        jql        => $jql,
        startAt    => $start,
        maxResults => $max,
        fields     => ['*navigable'],
    };

    my $query_json = $self->{_json}->encode($query);
    my $uri        = "$self->{auth_url}search/";

    my $request = POST $uri,
      Content_Type => 'application/json',
      Content      => $query_json;

    my $response = $self->{_ua}->request($request);

    if (!$response->is_success()) {
        die "Error searching for $jql from $start for $max results " . $response->status_line();
    }

    my $results = $self->{_json}->decode($response->decoded_content());
    return ($$results{total}, $$results{startAt}, $$results{maxResults}, $$results{issues});
}

sub all_search_results {
    my ($self, $jql, $max) = @_;

    my $start = 0;
    $max //= 100; # is a param for testing
    my $total = 0;
    my (@all_results, $issues);

    do {
        ($total, $start, $max, $issues) = $self->search_issues($jql, $start, $max);
        push @all_results, @$issues;
        $start += $max;
    } until (scalar(@$issues) < $max);

    return \@all_results;
}

sub attach_file_to_issue {
    my ($self, $key, $filename) = @_;

    my $uri = "$self->{auth_url}issue/$key/attachments";

    my $request = POST $uri,
      Content_Type        => 'form-data',
      'X-Atlassian-Token' => 'nocheck',             # required by JIRA XSRF protection
      Content             => [file => [$filename],];

    my $response = $self->{_ua}->request($request);

    if (!$response->is_success()) {
        die "Error attaching $filename to JIRA issue $key: " . $response->status_line();
    }

    return;
}

sub make_browse_url {
    my ($self, $key) = @_;
    # use url + browse + key to synthesize URL
    return $self->{url} . 'browse/' . $key;
}

=head1 BUGS

Please report bugs or feature requests to the author.

=head1 AUTHOR

Michael Friedman <frimicc@cpan.org>

=head1 COPYRIGHT AND LICENSE

This software is copyright (c) 2013 by Polyvore, Inc.

This is free software; you can redistribute it and/or modify it under
the same terms as the Perl 5 programming language system itself.

=cut

1;
