use 5.008008;
use ExtUtils::MakeMaker;

WriteMakefile(
	NAME              => 'JIRA::Client::Automated',
	VERSION_FROM      => 'lib/JIRA/Client/Automated.pm',
	PREREQ_PM         => {
		JSON => 0,
		LWP => 0,
	},
	ABSTRACT_FROM     => 'lib/JIRA/Client/Automated.pm', # retrieve abstract from module
	LICENSE           => 'perl',
);
