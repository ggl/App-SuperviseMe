requires 'AnyEvent';
requires 'YAML::Tiny';

on configure => sub {
    requires 'ExtUtils::MakeMaker', '6.30';
};

on build => sub {
    requires 'Test::Deep';
    requires 'Test::Fatal';
    requires 'Test::More', '0.98';
};
