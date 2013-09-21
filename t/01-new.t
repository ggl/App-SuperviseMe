#!perl

use strict;
use warnings;
use Test::More;
use Test::Deep;
use Test::Fatal;
use App::Sv;


subtest 'basic constructor' => sub {
	my $sm;

	is(exception { $sm = App::Sv->new({ run => { a => 'a' } }) },
		undef, 'new() lives with a simple command');
	ok($sm, '... got something back');
	is(ref($sm), 'App::Sv', '... of the proper type');
	cmp_deeply(
		$sm->{run}, 
		{
			a => {
				cmd => 'a',
				name => 'a',
				start_retries => 8,
				restart_delay => 1,
				start_wait => 1,
				stop_wait => 0
			}
		},
		'... with the expected command list'
	);

	is(exception { $sm = App::Sv->new({
		run => { a => 'a', b => { cmd => 'b' } } }) },
		undef, 'new() lives with two commands, one simple, one complex');
	ok($sm, '... got something back');
	is(ref($sm), 'App::Sv', '... of the proper type');
	cmp_deeply($sm->{run},
		{
			a => {
				cmd => 'a',
				name => 'a',
				start_retries => 8,
				restart_delay => 1,
				start_wait => 1,
				stop_wait => 0
			},
			b => {
				cmd => 'b',
				name => 'b',
				start_retries => 8,
				restart_delay => 1,
				start_wait => 1,
				stop_wait => 0
			}
		},
		'... with the expected command list'
	);

  like(exception { App::Sv->new({run => {}}) },
	qr{^Missing command list.*}, 'new() dies with empty run hash');
  like(exception { App::Sv->new },
	qr{^Commands must be passed as a HASH ref.*},
	'new() dies with no cmds list');
};

done_testing();
