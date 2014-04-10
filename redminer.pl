#/usr/bin/env perl

use 5.010;
use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib";

use Encode qw/encode/;
use Getopt::Long;
use Config::IniFiles;

use RedMiner::API;

my $conf_fname   = $ENV{HOME} . '/.redminer/redminer.conf';
my $layout_fname = $ENV{HOME} . '/.redminer/default-layout.conf';
my $project_id   = '';
my $project_name = 'ClientName.domain';

GetOptions(
	'conf=s'   => \$conf_fname,
	'layout=s' => \$layout_fname,
	'id=s'     => \$project_id,
	'name=s'   => \$project_name,
);

my $conf = Config::IniFiles->new( -file => $conf_fname );
if (!$conf) {
	die 'Unable to access master config';
}

if (!$project_id) {
	if ($project_name =~ /^[a-z.\-]+$/i) {
		$project_id = $project_name;
		$project_id =~ s/\./-/g;
	} else {
		die 'Invalid --id parameter';
	}
}

my $layout = Config::IniFiles->new( -file => $layout_fname );
if (!$layout) {
	warn 'Unable to access layout config';
}

my $redminer = RedMiner::API->new(
	host              => $conf->val('redmine', 'host') // '',
	user              => $conf->val('redmine', 'user') // '',
	pass              => $conf->val('redmine', 'pass') // '',
	key               => $conf->val('redmine',  'key') // '',
	work_as           => $conf->val('redmine',  'work_as') // '',
	no_wrapper_object => 1,
);

my $description = $layout? $layout->val('project', 'description') // '' : '';

say 'Creating a new project ' . $project_name;

my $project = $redminer->createProject({
	identifier  => $project_id  ,
	name        => $project_name,
	description => $description ,
});

if (!$project) {
	say STDERR 'Project was not created';
	say STDERR render_errors($redminer->errorDetails);
	exit 255;
}

my $pid = $project->{id};
say 'Project created with ID ' . $pid;

$redminer->updateProject($pid, {
	inherit_members => 1,
});

if ($layout) {
	my @sections = $layout->Sections;
	foreach my $section (@sections) {
		next if $section !~ /^subproject(-.+)$/;
		my $subproject_data = {
			identifier  => $project_id . $1,
			name        => $project_name  . ': ' . ($layout->val($section, 'name_suffix') // 'Subproject'),
			description => $layout->val($section, 'description') // '',
		};

		say 'Creating a new subproject ' . $subproject_data->{name};

		my $subproject = $redminer->createProject($subproject_data);
		if (!$subproject) {
			say STDERR 'Subproject was not created';
			say STDERR render_errors($redminer->errorDetails);
			next;
		}

		say 'Subproject created with ID ' . $subproject->{id};
		$redminer->updateProject($subproject->{id}, {
			parent_id       => $pid,
			inherit_members => 1,
		});
	}
}

# FIXME: handle limit/offset issue
my $perm_source = $layout? $layout->val('project', 'perm_source') : 0;
if ($perm_source) {
	my $memberships = $redminer->projectMemberships($perm_source);
	if ($memberships) {
		say 'Copying project permissions from a template project...';
		foreach my $membership (@{ $memberships->{memberships} }) {
			my $type = '';
			if (exists $membership->{group}) {
				$type = 'group';
			} elsif (exists $membership->{user}) {
				$type = 'user';
			}
			next if !length $type;

			my $new_membership = {
				user_id  => $membership->{$type}{id},
				role_ids => [],
			};
			for my $role (@{$membership->{roles}}) {
				next if $role->{inherited};
				push @{ $new_membership->{role_ids} }, $role->{id};
			}
			if ($new_membership->{user_id} && @{ $new_membership->{role_ids} }) {
				$redminer->createProjectMembership($pid, $new_membership);
			}
		}
		say 'Permissions copied';
	}
}

say 'Bye';
exit;

sub render_errors
{
	my $errors = shift;
	if (ref $errors ne 'HASH' && ref $errors->{errors} ne 'ARRAY') {
		return 'Unknown server errors';
	}
	return join "\n", 'Following error(s) reported:', map {
		"\t* " . Encode::encode('UTF-8', $_)
	} @{ $errors->{errors} };
}
