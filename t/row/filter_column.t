use strict;
use warnings;

use Test::More;
use Test::Exception;
use lib qw(t/lib);
use DBICTest;

my $from_storage_ran = 0;
my $to_storage_ran = 0;
my $schema = DBICTest->init_schema();
DBICTest::Schema::Artist->load_components(qw(FilterColumn InflateColumn));
DBICTest::Schema::Artist->filter_column(rank => {
  filter_from_storage => sub { $from_storage_ran++; $_[1] * 2 },
  filter_to_storage   => sub { $to_storage_ran++; $_[1] / 2 },
});
Class::C3->reinitialize() if DBIx::Class::_ENV_::OLD_MRO;

my $artist = $schema->resultset('Artist')->create( { rank => 20 } );

# this should be using the cursor directly, no inflation/processing of any sort
my ($raw_db_rank) = $schema->resultset('Artist')
                             ->search ($artist->ident_condition)
                               ->get_column('rank')
                                ->_resultset
                                 ->cursor
                                  ->next;

is ($raw_db_rank, 10, 'INSERT: correctly unfiltered on insertion');

for my $reloaded (0, 1) {
  my $test = $reloaded ? 'reloaded' : 'stored';
  $artist->discard_changes if $reloaded;

  is( $artist->rank , 20, "got $test filtered rank" );
}

$artist->update;
$artist->discard_changes;
is( $artist->rank , 20, "got filtered rank" );

$artist->update ({ rank => 40 });
($raw_db_rank) = $schema->resultset('Artist')
                             ->search ($artist->ident_condition)
                               ->get_column('rank')
                                ->_resultset
                                 ->cursor
                                  ->next;
is ($raw_db_rank, 20, 'UPDATE: correctly unflitered on update');

$artist->discard_changes;
$artist->rank(40);
ok( !$artist->is_column_changed('rank'), 'column is not dirty after setting the same value' );

MC: {
   my $cd = $schema->resultset('CD')->create({
      artist => { rank => 20 },
      title => 'fun time city!',
      year => 'forevertime',
   });
   ($raw_db_rank) = $schema->resultset('Artist')
                                ->search ($cd->artist->ident_condition)
                                  ->get_column('rank')
                                   ->_resultset
                                    ->cursor
                                     ->next;

   is $raw_db_rank, 10, 'artist rank gets correctly unfiltered w/ MC';
   is $cd->artist->rank, 20, 'artist rank gets correctly filtered w/ MC';
}

CACHE_TEST: {
  my $expected_from = $from_storage_ran;
  my $expected_to   = $to_storage_ran;

  # ensure we are creating a fresh obj
  $artist = $schema->resultset('Artist')->single($artist->ident_condition);

  is $from_storage_ran, $expected_from, 'from has not run yet';
  is $to_storage_ran, $expected_to, 'to has not run yet';

  $artist->rank;
  cmp_ok (
    $artist->get_filtered_column('rank'),
      '!=',
    $artist->get_column('rank'),
    'filter/unfilter differ'
  );
  is $from_storage_ran, ++$expected_from, 'from ran once, therefor caches';
  is $to_storage_ran, $expected_to,  'to did not run';

  $artist->rank(6);
  is $from_storage_ran, $expected_from, 'from did not run';
  is $to_storage_ran, ++$expected_to,  'to ran once';

  ok ($artist->is_column_changed ('rank'), 'Column marked as dirty');

  $artist->rank;
  is $from_storage_ran, $expected_from, 'from did not run';
  is $to_storage_ran, $expected_to,  'to did not run';

  $artist->update;

  $artist->set_column(rank => 3);
  ok (! $artist->is_column_changed ('rank'), 'Column not marked as dirty on same set_column value');
  is ($artist->rank, '6', 'Column set properly (cache blown)');
  is $from_storage_ran, ++$expected_from, 'from ran once (set_column blew cache)';
  is $to_storage_ran, $expected_to,  'to did not run';

  $artist->rank(6);
  ok (! $artist->is_column_changed ('rank'), 'Column not marked as dirty on same accessor-set value');
  is ($artist->rank, '6', 'Column set properly');
  is $from_storage_ran, $expected_from, 'from did not run';
  is $to_storage_ran, ++$expected_to,  'to did run once (call in to set_column)';

  $artist->store_column(rank => 4);
  ok (! $artist->is_column_changed ('rank'), 'Column not marked as dirty on differing store_column value');
  is ($artist->rank, '8', 'Cache properly blown');
  is $from_storage_ran, ++$expected_from, 'from did not run';
  is $to_storage_ran, $expected_to,  'to did not run';
}

# test in-memory operations
for my $artist_maker (
  sub { $schema->resultset('Artist')->new({ rank => 42 }) },
  sub { my $art = $schema->resultset('Artist')->new({}); $art->rank(42); $art },
) {

  my $expected_from = $from_storage_ran;
  my $expected_to   = $to_storage_ran;

  my $artist = $artist_maker->();

  is $from_storage_ran, $expected_from, 'from has not run yet';
  is $to_storage_ran, $expected_to, 'to has not run yet';

  ok( ! $artist->has_column_loaded('artistid'), 'pk not loaded' );
  ok( $artist->has_column_loaded('rank'), 'Filtered column marked as loaded under new' );
  is( $artist->rank, 42, 'Proper unfiltered value' );
  is( $artist->get_column('rank'), 21, 'Proper filtered value' );
}

# test literals
for my $v ( \ '16', \[ '?', '16' ] ) {
  my $art = $schema->resultset('Artist')->new({ rank => 10 });
  $art->rank($v);

  is_deeply( $art->rank, $v);
  is_deeply( $art->get_filtered_column("rank"), $v);
  is_deeply( $art->get_column("rank"), $v);

  $art->insert;
  $art->discard_changes;

  is ($art->get_column("rank"), 16, "Literal inserted into database properly");
  is ($art->rank, 32, "filtering still works");

  $art->update({ rank => $v });

  is_deeply( $art->rank, $v);
  is_deeply( $art->get_filtered_column("rank"), $v);
  is_deeply( $art->get_column("rank"), $v);

  $art->discard_changes;

  is ($art->get_column("rank"), 16, "Literal inserted into database properly");
  is ($art->rank, 32, "filtering still works");
}

IC_DIE: {
  throws_ok {
     DBICTest::Schema::Artist->inflate_column(rank =>
        { inflate => sub {}, deflate => sub {} }
     );
  } qr/InflateColumn can not be used on a column with a declared FilterColumn filter/, q(Can't inflate column after filter column);

  DBICTest::Schema::Artist->inflate_column(name =>
     { inflate => sub {}, deflate => sub {} }
  );

  throws_ok {
     DBICTest::Schema::Artist->filter_column(name => {
        filter_to_storage => sub {},
        filter_from_storage => sub {}
     });
  } qr/FilterColumn can not be used on a column with a declared InflateColumn inflator/, q(Can't filter column after inflate column);
}

# test when we do not set both filter_from_storage/filter_to_storage
DBICTest::Schema::Artist->filter_column(rank => {
  filter_to_storage => sub { $to_storage_ran++; $_[1] },
});
Class::C3->reinitialize() if DBIx::Class::_ENV_::OLD_MRO;

ASYMMETRIC_TO_TEST: {
  # initialise value
  $artist->rank(20);
  $artist->update;

  my $expected_from = $from_storage_ran;
  my $expected_to   = $to_storage_ran;

  $artist->rank(10);
  ok ($artist->is_column_changed ('rank'), 'Column marked as dirty on accessor-set value');
  is ($artist->rank, '10', 'Column set properly');
  is $from_storage_ran, $expected_from, 'from did not run';
  is $to_storage_ran, ++$expected_to,  'to did run';

  $artist->discard_changes;

  is ($artist->rank, '20', 'Column set properly');
  is $from_storage_ran, $expected_from, 'from did not run';
  is $to_storage_ran, $expected_to,  'to did not run';
}

DBICTest::Schema::Artist->filter_column(rank => {
  filter_from_storage => sub { $from_storage_ran++; $_[1] },
});
Class::C3->reinitialize() if DBIx::Class::_ENV_::OLD_MRO;

ASYMMETRIC_FROM_TEST: {
  # initialise value
  $artist->rank(23);
  $artist->update;

  my $expected_from = $from_storage_ran;
  my $expected_to   = $to_storage_ran;

  $artist->rank(13);
  ok ($artist->is_column_changed ('rank'), 'Column marked as dirty on accessor-set value');
  is ($artist->rank, '13', 'Column set properly');
  is $from_storage_ran, $expected_from, 'from did not run';
  is $to_storage_ran, $expected_to,  'to did not run';

  $artist->discard_changes;

  is ($artist->rank, '23', 'Column set properly');
  is $from_storage_ran, ++$expected_from, 'from did run';
  is $to_storage_ran, $expected_to,  'to did not run';
}

throws_ok { DBICTest::Schema::Artist->filter_column( rank => {} ) }
  qr/\QAn invocation of filter_column() must specify either a filter_from_storage or filter_to_storage/,
  'Correctly throws exception for empty attributes'
;

done_testing;
