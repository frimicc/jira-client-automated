use 5.010;
use strict;
use warnings;

package JIRA::Client::Automated;

=head1 NAME

JIRA::Client::Automated - A JIRA REST Client for automated scripts

=head1 SYNOPSIS

    use JIRA::Client::Automated;

    my $jira = JIRA::Client::Automated->new($url, $user, $password);
    my $issue = $jira->create_issue($project, $type, $summary, $description);
    my $search_results = $jira->search_issues($jql, 1, 100); # query should be a single string of JQL
    my @issues = $jira->all_search_results($jql, 1000); # query should be a single string of JQL
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

L<https://developer.atlassian.com/display/JIRADEV/JIRA+REST+APIs>

This module is designed for the JIRA 5.2.11 REST API, as of March 2013, but it seems to work fine with JIRA 6.0 as well. Your mileage may vary with future versions.

=head1 JIRA ISSUE HASH FORMAT

When you work with an issue in JIRA's REST API, it gives you a JSON file that follows this spec:

L<https://developer.atlassian.com/display/JIRADEV/The+Shape+of+an+Issue+in+JIRA+REST+APIs>

JIRA::Client::Automated tries to be nice to you and not make you deal directly with JSON. When you create a new issue, you can pass in just the pieces you want and L</"create_issue"> will transform them to JSON for you. The same for closing and deleting issues. However there's not much I can do about updating or transitioning issues. Each JIRA installation will have different fields available for each issue type and transition screen and only you will know what they are. So in those cases you'll need to pass in an "update_hash" which will be transformed to the proper JSON by the method.

An update_hash looks like this:

    { field => value, field2 => value2, ...}

For example:

    {
        host_id => "example.com",
        { resolution => { name => "Resolved" } }
    }

If you do not read JIRA's documentation about their JSON format you will hurt yourself banging your head against your desk in frustration the first few times you try to use L</"update_issue">. Please RTFM.

Note that even though JIRA requires JSON, JIRA::Client::Automated will helpfully translate it to and from regular hashes for you. You only pass hashes to JIRA::Client::Automated, not direct JSON.

But, since you aren't going to read the documentation, I recommend connecting to your JIRA server and calling L</"get_issue"> with a key you know exists and then dump the result. That'll get you started.

=head1 METHODS

=cut

use JSON;
use LWP::UserAgent;
use HTTP::Request;
use HTTP::Request::Common qw(GET POST PUT DELETE);
use LWP::Protocol::https;

=head2 new

    my $jira = JIRA::Client::Automated->new($url, $user, $password);

Create a new JIRA::Client::Automated object by passing in the following:

=over 3

=item 1.

URL for the JIRA server, such as "http://example.atlassian.net/"

=item 2.

Username to use to login to the JIRA server

=item 3.

Password for that user

=back

All three parameters are required. JIRA::Client::Automated must connect to the JIRA instance using I<some> username and password. I recommend setting up a special "auto" or "batch" username to use just for use by scripts.

If you are using Google Account integration, the username and password to use are the ones you set up at the very beginning of the registration process and then never used again because Google logged you in.

=cut

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

    if ($auth_url !~ m|https?://|) {
        die "URL for JIRA must be absolute, including 'http://' or 'https://'.";
    }

    my $self = { url => $url, auth_url => $auth_url, user => $user, password => $password };
    bless $self, $class;

    # cached UserAgent for talking to JIRA
    $self->{_ua} = LWP::UserAgent->new();

    # cached JSON object for handling conversions
    $self->{_json} = JSON->new->utf8();

    return $self;
}

=head2 create_issue

    my $issue = $jira->create_issue($project, $type, $summary, $description);

Creating a new issue requires the project key, type ("Bug", "Task", etc.), and a summary and description. Other fields that are on the new issue form could be supported by a subclass, but it's probably easier to use L</"update_issue"> with JIRA's syntax for now.

Returns a hash containing the information about the new issue or dies if there is an error. See L</"JIRA ISSUE HASH FORMAT"> for details of the hash.

=cut

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

    $request->authorization_basic($self->{user}, $self->{password});

    my $response = $self->{_ua}->request($request);

    if (!$response->is_success()) {
        die "Error creating new JIRA issue $summary " . $response->status_line();
    }

    my $new_issue = $self->{_json}->decode($response->decoded_content());

    return $new_issue;
}

=head2 update_issue

    $jira->update_issue($key, $update_hash);

Updating an issue is one place where JIRA's REST API shows through. You pass in the issue key and update_hash with only the field changes you want in it. See L</"JIRA ISSUE HASH FORMAT">, above, for details about the format of the update_hash.

=cut

sub update_issue {
    my ($self, $key, $update_hash) = @_;

    my $issue = { fields => $update_hash };

    my $issue_json = $self->{_json}->encode($issue);
    my $uri        = "$self->{auth_url}issue/$key";

    my $request = PUT $uri,
      Content_Type => 'application/json',
      Content      => $issue_json;

    $request->authorization_basic($self->{user}, $self->{password});

    my $response = $self->{_ua}->request($request);

    if (!$response->is_success()) {
        die "Error updating JIRA issue $key " . $response->status_line();
    }

    return $key;
}

=head2 get_issue

    my $issue = $jira->get_issue($key);

You can get the details for any issue, given its key. This call returns a hash containing the information for the issue in JIRA's format. See L</"JIRA ISSUE HASH FORMAT"> for details.

=cut

sub get_issue {
    my ($self, $key) = @_;
    my $uri = "$self->{auth_url}issue/$key";

    my $request = GET $uri, Content_Type => 'application/json';

    $request->authorization_basic($self->{user}, $self->{password});

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

    $request->authorization_basic($self->{user}, $self->{password});

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

=head2 transition_issue

    $jira->transition_issue($key, $transition, $update_hash);

Transitioning an issue is what happens when you click the button that says "Resolve Issue" or "Start Progress" on it. Doing this from code is harder, but JIRA::Client::Automated makes it as easy as possible. You pass this method the issue key, the name of the transition (spacing and capitalization matter), and an optional update_hash containing any fields on the transition screen that you want to update.

If you have required fields on the transition screen (such as "Resolution" for the "Resolve Issue" screen), you must pass those fields in as part of the update_hash or you will get an error from the server. See L</"JIRA ISSUE HASH FORMAT"> for the format of the update_hash.

=cut

sub transition_issue {
    my ($self, $key, $t_name, $t_hash) = @_;

    my $t_id = $self->_get_transition_id($key, $t_name);
    $$t_hash{transition} = { id => $t_id };

    my $t_json = $self->{_json}->encode($t_hash);
    my $uri    = "$self->{auth_url}issue/$key/transitions";

    my $request = POST $uri,
      Content_Type => 'application/json',
      Content      => $t_json;

    $request->authorization_basic($self->{user}, $self->{password});

    my $response = $self->{_ua}->request($request);

    if (!$response->is_success()) {
        die "Error with $t_name for JIRA issue $key: " . $response->status_line();
    }

    return $key;
}

=head2 close_issue

    $jira->close_issue($key, $resolve, $message);

Pass in the resolution reason and an optional comment to close an issue. Using this method requires that the issue is is a status where it can use the "Close Issue" transition. If not, you will get an error from the server.

Resolution ("Fixed", "Won't Fix", etc.) is only required if the issue hasn't already been resolved in an earlier transition. If you try to resolve an issue twice, you will get an error.

If you do not supply a comment, the default value is "Issue closed by script".

If your JIRA installation has extra required fields on the "Close Issue" screen then you'll want to use the more generic L</"transition_issue"> call instead.

=cut

sub close_issue {
    my ($self, $key, $resolve, $comment) = @_;

    $comment //= 'Issue closed by script';

    my ($closing);
    if ($resolve) {
        $closing = {
            update => { comment    => [{ add => { body => $comment }, }] },
            fields => { resolution => { name => $resolve } },
        };
    } else {
        $closing = { update => { comment => [{ add => { body => $comment }, }] }, };
    }

    return $self->transition_issue($key, 'Close Issue', $closing);
}

=head2 delete_issue

    $jira->delete_issue($key);

Deleting issues is for testing your JIRA code. In real situations you almost always want to close unwanted issues with an "Oops!" resolution instead.

=cut

sub delete_issue {
    my ($self, $key) = @_;

    my $uri = "$self->{auth_url}issue/$key";

    my $request = DELETE $uri;
    $request->authorization_basic($self->{user}, $self->{password});

    my $response = $self->{_ua}->request($request);

    if (!$response->is_success()) {
        die "Error deleting JIRA issue $key " . $response->status_line();
    }

    return $key;
}

=head2 create_comment

    $jira->create_comment($key, $text);

You may use any valid JIRA markup in comment text. (This is handy for tables of values explaining why something in the database is wrong.) Note that comments are all created by the user you used to create your JIRA::Client::Automated object, so you'll see that name often.

=cut

sub create_comment {
    my ($self, $key, $text) = @_;

    my $comment = { body => $text };

    my $comment_json = $self->{_json}->encode($comment);
    my $uri          = "$self->{auth_url}issue/$key/comment";

    my $request = POST $uri,
      Content_Type => 'application/json',
      Content      => $comment_json;

    $request->authorization_basic($self->{user}, $self->{password});

    my $response = $self->{_ua}->request($request);

    if (!$response->is_success()) {
        die "Error creating new JIRA comment for $key : $text " . $response->status_line();
    }

    my $new_comment = $self->{_json}->decode($response->decoded_content());

    return $new_comment;
}

=head2 search_issues

    my @search_results = $jira->search_issues($jql, 1, 100);

You've used JQL before, when you did an "Advanced Search" in the JIRA web interface. That's the only way to search via the REST API.

This is a paged method. Pass in the starting result number and number of results per page and it will return issues a page at a time. If you know you want all of the results, you can use L</"all_search_results"> instead.

This method returns a hashref containing up to five values:

=over 3

=item 1.

total => total number of results

=item 2.

start => result number for the first result

=item 3.

max => maximum number of results per page

=item 4.

issues => an arrayref containing the actual found issues

=item 5.

errors => an arrayref containing error messages

=back

For example, to page through all results C<$max> at a time:

    my (@all_results, $issues);
    do {
        $results = $self->search_issues($jql, $start, $max);
        if ($results->{errors}) {
            die join "\n", @{$results->{errors}};
        }
        @issues = @{$results->{issues}};
        push @all_results, @issues;
        $start += $max;
    } until (scalar(@$issues) < $max);

(Or just use L</"all_search_results"> instead.)

=cut

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

    $request->authorization_basic($self->{user}, $self->{password});

    my $response = $self->{_ua}->request($request);

    if (!$response->is_success()) {
        if ($response->code() == 400) {
            my $error_msg = $self->{_json}->decode($response->decoded_content());
            return { total => 0, errors => $error_msg->{errorMessages} };
        } else {
            die "Error searching for $jql from $start for $max results " . $response->status_line();
        }
    }

    my $results = $self->{_json}->decode($response->decoded_content());

    # TODO: make this return a hash labeling the metadata instead of just a list.
    return {
        total  => $$results{total},
        start  => $$results{startAt},
        max    => $$results{maxResults},
        issues => $$results{issues} };
}

=head2 all_search_results

    my @issues = $jira->all_search_results($jql, 1000);

Like L</"search_issues">, but returns all the results as an array of issues. You can specify the maximum number to return, but no matter what, it can't return more than the value of jira.search.views.default.max for your JIRA installation.

=cut

sub all_search_results {
    my ($self, $jql, $max) = @_;

    my $start = 0;
    $max //= 100; # is a param for testing
    my $total = 0;
    my (@all_results, @issues, $results);

    do {
        $results = $self->search_issues($jql, $start, $max);
        if ($results->{errors}) {
            die join "\n", @{ $results->{errors} };
        }
        @issues = @{ $results->{issues} };
        push @all_results, @issues;
        $start += $max;
    } until (scalar(@issues) < $max);

    return @all_results;
}

=head2 attach_file_to_issue

    $jira->attach_file_to_issue($key, $filename);

This method does not let you attach a comment to the issue at the same time. You'll need to call L</"create_comment"> for that.

Watch out for file permissions! If the user running the script does not have permission to read the file it is trying to upload, you'll get weird errors.

=cut

sub attach_file_to_issue {
    my ($self, $key, $filename) = @_;

    my $uri = "$self->{auth_url}issue/$key/attachments";

    my $request = POST $uri,
      Content_Type        => 'form-data',
      'X-Atlassian-Token' => 'nocheck',             # required by JIRA XSRF protection
      Content             => [file => [$filename],];

    $request->authorization_basic($self->{user}, $self->{password});

    my $response = $self->{_ua}->request($request);

    if (!$response->is_success()) {
        die "Error attaching $filename to JIRA issue $key: " . $response->status_line();
    }

    my $new_attachment = $self->{_json}->decode($response->decoded_content());

    return $new_attachment;
}

=head2 make_browse_url

    my $url = $jira->make_browse_url($key);

A helper method to make emails containing lists of bugs easier to use. This just appends the key to the URL for the JIRA server so that you can click on it and go directly to that issue.

=cut

sub make_browse_url {
    my ($self, $key) = @_;
    # use url + browse + key to synthesize URL
    return $self->{url} . 'browse/' . $key;
}

=head1 FAQ

=head2 Why is there no object for a JIRA issue?

Because it seemed silly. You I<could> write such an object and give it methods to transition itself, close itself, etc., but when you are working with JIRA from batch scripts, you're never really working with just one issue at a time. And when you have a hundred of them, it's easier to not objectify them and just use JIRA::Client::Automated as a mediator. That said, if this is important to you, I wouldn't say no to a patch offering this option.

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
