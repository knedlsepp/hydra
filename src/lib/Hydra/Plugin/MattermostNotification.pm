package Hydra::Plugin::MattermostNotification;

use strict;
use warnings;
use parent 'Hydra::Plugin';
use HTTP::Request;
use LWP::UserAgent;
use Hydra::Helper::CatalystUtils;
use JSON::MaybeXS;

=head1 NAME

MattermostNotification - hydra-notify plugin for sending Mattermost notifications about
build results

=head1 DESCRIPTION

This plugin reports build statuses to various Mattermost channels. One can configure
which builds are reported to which channels, and whether reports should be on
state change (regressions and improvements), or for each build.

=head1 CONFIGURATION

The module is configured using the C<mattermost> block in Hydra's config file. There
can be multiple such blocks in the config file, each configuring different (or
even the same) set of builds and how they report to Mattermost channels.

The following entries are recognized in the C<mattermost> block:

=over 4

=item jobs

A pattern for job names. All builds whose job name matches this pattern will
emit a message to the designated Mattermost channel (see C<channel_id>). The pattern will
match the whole name, thus leaving this field empty will result in no
notifications being sent. To match on all builds, use C<.*>.

=item url

The URL to a Mattermost server.

=item force

(Optional) An I<integer> indicating whether to report on every build or only on
changes in the status. If not provided, defaults to 0, that is, sending reports
only when build status changes from success to failure, and vice-versa. Any
other value results in reporting on every build.

=item channel_id

ID of the channel

=item auth_token

Auth token for bot user

=back

=cut

sub isEnabled {
    my ($self) = @_;
    return defined $self->{config}->{mattermost};
}

sub buildFinished {
    my ($self, $topbuild, $dependents) = @_;
    my $cfg = $self->{config}->{mattermost};
    my @config = defined $cfg ? ref $cfg eq "ARRAY" ? @$cfg : ($cfg) : ();

    my $baseurl = $self->{config}->{'base_uri'} || "http://localhost:3000";

    # Figure out to which channelss to send notification.  For each channel
    # we send one aggregate message.
    my %channels;
    foreach my $build ($topbuild, @{$dependents}) {
        my $jobName = showJobName $build;
        my $buildStatus = $build->buildstatus;
        my $cancelledOrAborted = $buildStatus == 4 || $buildStatus == 3;

        my $prevBuild = getPreviousBuild($build);
        my $sameAsPrevious = defined $prevBuild && ($buildStatus == $prevBuild->buildstatus);
        my $prevBuildStatus = (defined $prevBuild) ? $prevBuild->buildstatus : -1;
        my $prevBuildId = (defined $prevBuild) ? $prevBuild->id : -1;

        print STDERR "MattermostNotification_Debug job name $jobName status $buildStatus (previous: $prevBuildStatus from $prevBuildId)\n";

        foreach my $channel (@config) {
            next unless $jobName =~ /^$channel->{jobs}$/;

            my $force = $channel->{force};

            print STDERR "MattermostNotification_Debug found match with '$channel->{jobs}' with force=$force\n";

            # If build is cancelled or aborted, do not send Mattermost notification.
            next if ! $force && $cancelledOrAborted;

            # If there is a previous (that is not cancelled or aborted) build
            # with same buildstatus, do not send Mattermost notification.
            next if ! $force && $sameAsPrevious;

            print STDERR "MattermostNotification_Debug adding $jobName to the report list\n";
            $channels{$channel->{url}} //= { channel => $channel, builds => [] };
            push @{$channels{$channel->{url}}->{builds}}, $build;
        }
    }

    return if scalar keys %channels == 0;

    # Send a message to each room.
    foreach my $url (keys %channels) {
        my $channel = $channels{$url};
        my @deps = grep { $_->id != $topbuild->id } @{$channel->{builds}};

        my $status =
            $topbuild->buildstatus == 0 ? ":white_check_mark: Fixed" :
            $topbuild->buildstatus == 4 ? ":warning: Failure" :
            ":x: Failure";

        my $text = "";
        $text .= "$status - Job [". showJobName($topbuild) . "](" . "$baseurl/job/${\$topbuild->jobset->get_column('project')}/${\$topbuild->jobset->get_column('name')}/${\$topbuild->get_column('job')}" . ")";
        $text .= " (and ${\scalar @deps} others)" if scalar @deps > 0;
        $text .= ": [" . showStatus($topbuild) . "]($baseurl/build/${\$topbuild->id}).";

        print STDERR "MattermostNotification_Debug POSTing to url ending with: ${\substr $url, -8}\n";

        my $msg =
        {
            channel_id => $channel->{channel}->{channel_id},
            message => $text,
        };

        my $req = HTTP::Request->new('POST', "$url/api/v4/posts");
        $req->header('Content-Type' => 'application/json', 'Authorization' => 'Bearer ' . $channel->{channel}->{auth_token});
        $req->content(encode_json($msg));
        my $ua = LWP::UserAgent->new();
        $ua->request($req);
    }
}

1;
