#!/usr/bin/perl
##---------------------------------------------------------------------------##
##  File:
##      @(#) RepeatUtil.pm
##  Authors:
##      Robert M. Hubley   rhubley@systemsbiology.org
##      Arian Smit         asmit@systemsbiology.org
##  Description:
##      A module containing several useful subroutines
##      used by the RepeatModeler suite of programs.
##
#******************************************************************************
#* Copyright (C) Institute for Systems Biology 2004 Developed by
#* Robert Hubley, Arian Smit and Arnie Kas.
#*
#* This work is licensed under the Open Source License v2.1.  To view a copy
#* of this license, visit http://www.opensource.org/licenses/osl-2.1.php or
#* see the license.txt file contained in this distribution.
#*
###############################################################################
#  ChangeLog:
#
#    $Log: RepeatUtil.pm,v $
#    Revision 1.29  2017/04/05 00:03:31  rhubley
#    Cleanup before a distribution
#
#
###############################################################################

=head1 NAME

RepeatUtil.pm - Library functions for RepeatModeler

=head1 SYNOPSIS

use RepeatUtil;

Usage:


=head1 DESCRIPTION

=head1 SEE ALSO

=over 4

RepeatModeler 

=back

=head1 COPYRIGHT

Copyright 2005 Institute for Systems Biology

=head1 AUTHOR

Robert Hubley <rhubley@systemsbiology.org>
Arian Smit <asmit@systemsbiology.org>

=head1 ATTRIBUTES

=cut

#
# Module Dependence
#
package RepeatUtil;
use strict;
use FindBin;
use lib $FindBin::RealBin;
use Data::Dumper;
use Carp;
use File::Basename;

# RepeatMasker Libraries
use RepModelConfig;
use lib $RepModelConfig::configuration->{'REPEATMASKER_DIR'}->{'value'};
use WUBlastSearchEngine;
use CrossmatchSearchEngine;
use MultAln;
use SeedAlignment;
use SeqDBI;
use SearchResultCollection;
use SimpleBatcher;

use vars qw(@ISA @EXPORT @EXPORT_OK %EXPORT_TAGS $VERSION);

require Exporter;

@ISA = qw(Exporter);

@EXPORT = qw();

@EXPORT_OK = qw();

%EXPORT_TAGS = ( all => [ @EXPORT_OK ] );

my $CLASS = "RepeatUtil";
my $DEBUG = 0;
$DEBUG = 1 if ( $RepModelConfig::DEBUGALL == 1 );
my $config        = $RepModelConfig::configuration;
my $XDFORMAT_PRGM = $config->{'ABBLAST_DIR'}->{'value'} . "/xdformat";
my $WUBLASTN_PRGM = $config->{'ABBLAST_DIR'}->{'value'} . "/blastn";

##---------------------------------------------------------------------##

=head2 ncbiMaskDatabase()

  Use: ncbiMaskDatabase( makeDBPath => "/usr/local/rmblast/makeblastdb",
                      dbCMDPath => "/usr/local/rmblast/blastdbcmd",
                     fastaFile => "/jo/bob/seq.fa",
                     consensi => "/jo/bob/lib/reps.fa",
                     searchEngine => $searchEngine,
                     [instSeqFile => "/jo/bob/instances.out"] );

=cut

##---------------------------------------------------------------------##
sub ncbiMaskDatabase {
  my %parameters = @_;

  # Parameter checking
  die $CLASS
      . "::ncbiMaskDatabase(): Missing or invalid makeDBPath "
      . "parameter!\n"
      if (    !defined $parameters{'makeDBPath'}
           || !-x $parameters{'makeDBPath'} );
  my $makeDBPath = $parameters{'makeDBPath'};

  die $CLASS
      . "::ncbiMaskDatabase(): Missing or invalid dbCMDPath "
      . "parameter!\n"
      if (    !defined $parameters{'dbCMDPath'}
           || !-x $parameters{'dbCMDPath'} );
  my $dbCMDPath = $parameters{'dbCMDPath'};

  die $CLASS
      . "::ncbiMaskDatabase(): Missing or invalid aliasPath "
      . "parameter!\n"
      if (    !defined $parameters{'aliasPath'}
           || !-x $parameters{'aliasPath'} );
  my $aliasPath = $parameters{'aliasPath'};

  die $CLASS . "::ncbiMaskDatabase(): Missing workingDir parameter!\n"
      if (    !defined $parameters{'workingDir'}
           || !-d $parameters{'workingDir'} );
  my $workingDir = $parameters{'workingDir'};

  die $CLASS . "::ncbiMaskDatabase(): Missing fastaFile parameter!\n"
      if (    !defined $parameters{'fastaFile'}
           || !-s $parameters{'fastaFile'} );
  my $fastaFile = $parameters{'fastaFile'};

  #my $tempDir   = dirname( $fastaFile );

  die $CLASS . "::ncbiMaskDatabase(): Missing consensi parameter!\n"
      if (    !defined $parameters{'consensi'}
           || !-s $parameters{'consensi'} );
  my $consensi = $parameters{'consensi'};

  die $CLASS . "::ncbiMaskDatabase(): Missing searchEngine parameter!\n"
      if ( !defined $parameters{'searchEngine'} );
  my $searchEngine = $parameters{'searchEngine'};

  my $instSeqFile;
  $instSeqFile = $parameters{'instSeqFile'}
      if ( defined $parameters{'instSeqFile'} );

  # Setup the temporary database
  my $index  = 1;
  my $dbName = "tmpMaskDB-$index";
  while ( -s "$workingDir/$dbName.nhr" ) {
    $index++;
    $dbName = "tmpMaskDB-$index";
  }
  system(
"$makeDBPath -blastdb_version 4 -out $workingDir/$dbName -parse_seqids -dbtype nucl -in $fastaFile > /dev/null 2>&1"
  );
  my $tmpDBStats  = `$dbCMDPath -db $workingDir/$dbName -info 2>&1`;
  my $dbNumSeqs   = 0;
  my $dbMaxSeqLen = 0;

  foreach my $line ( split /[\n\r]+/, $tmpDBStats ) {
    if ( $line =~ /\s+([\d\,]+)\s+sequences;\s+([\d\,]+)\s+total bases.*$/ ) {
      $dbNumSeqs = $1;
      $dbNumSeqs =~ s/,//g;
      next;
    }
    if ( $line =~ /Longest sequence:\s*([\d,]+)/ ) {
      $dbMaxSeqLen = $1;
      $dbMaxSeqLen =~ s/,//g;
      last;
    }
  }
  my $maxBatchSize = 100;
  my $batchSize    = 5;
  print $CLASS
      . "::ncbiMaskDatabase(): tmpDBName = $dbName size = $dbNumSeqs"
      . " longest sequence size = $dbMaxSeqLen batchSize = $batchSize\n"
      if ( $DEBUG );

  my $maskDB = FastaDB->new( fileName => $fastaFile,
                             openMode => SeqDBI::ReadOnly );
  open OUT, ">$fastaFile.masked";

  # Setup the Query/Subject
  $searchEngine->setQuery( $consensi );
  $searchEngine->setSubject( "$workingDir/$dbName" );
  $searchEngine->setTempDir( $workingDir );

  my $INST;
  if ( defined $parameters{'instSeqFile'} ) {
    open $INST, ">$parameters{'instSeqFile'}";
  }


  # Check to make sure additional parameters haven't already
  # been set
  my $additionalParams = "";
  $additionalParams = $searchEngine->getAdditionalParameters();
  $additionalParams = "" if ( !defined $additionalParams );

  my $repeatsMasked = 0;
  my %idsSeen       = ();
  for ( my $i = 1 ; $i <= $dbNumSeqs ; $i += $batchSize ) {
    my $dbEnd = $i + $batchSize - 1;
    $dbEnd = $dbNumSeqs if ( $dbEnd > $dbNumSeqs );
    print "     - Masking $i - $dbEnd of $dbNumSeqs\n";

    # Create a gilist
    my @giList = ( $i .. $dbEnd );
    open GI, ">$workingDir/$dbName-gilist.txt"
        or die "$CLASS"
        . "::ncbiMaskDatabase(): Could not open up file $dbName-gilist.txt for writing!\n";
    print GI join( "\n", @giList ) . "\n";
    close GI;
    system(
"$aliasPath -gi_file_in $workingDir/$dbName-gilist.txt -gi_file_out $workingDir/$dbName-gilist > /dev/null 2>&1"
    );

    $searchEngine->setAdditionalParameters(
                     " $additionalParams -gilist $workingDir/$dbName-gilist " );

    my ( $status, $resultCollection ) = $searchEngine->search();
    if ( $status ) {
      print STDERR "\nERROR from search engine (", $? >> 8, ") \n";
    }
    elsif ( $resultCollection->size() > 0 ) {

      if ( $resultCollection->size() < 500000 ) {
        $batchSize += 10;
        $batchSize = $maxBatchSize if ( $batchSize > $maxBatchSize );

        #print "Raising batch size to $batchSize, resultColl size = " .
        #      $resultCollection->size() . "\n";
      }

      print "    -- Collecting " . $resultCollection->size() . " ranges...\n"
          if ( $DEBUG );
      my %maskRanges = ();
      my $seqID;

      for ( my $k = 0 ; $k < $resultCollection->size() ; $k++ ) {

        $seqID = $resultCollection->get( $k )->getSubjName();
        my $startIncr   = 0;
        my $endIncr     = 0;
        my $globalSeqID = $seqID;

        # TODO....fix this!!!!
        if ( $seqID =~ /(\S+)_(\d+)-\d+$/ ) {
          $globalSeqID = $1;
          $startIncr   = $2;
          $endIncr     = $2;
        }
        $seqID = $1 if ( $seqID =~ /(\S+)\s+\S.*/ );

        my $result     = $resultCollection->get( $k );
        my $start      = $result->getSubjStart();
        my $end        = $result->getSubjEnd();
        my $rangeStart = $start - 1;
        my $rangeLen   = ( $end - $start + 1 );
        push @{ $maskRanges{$seqID} }, [ $rangeStart, $rangeLen ];

        # Adjust to global coords
        $start += $startIncr;
        $end   += $endIncr;

        # Store the minus strand hits with reverse index notation
        if ( $result->getOrientation() eq "C" ) {
          my $tmp = $start;
          $start = $end;
          $end   = $tmp;
        }

        if ( defined $INST ) {
          print $INST ""
              . $result->getScore . " "
              . $result->getQueryName() . " "
              . "$globalSeqID $start $end "
              . $result->getQueryStart() . " "
              . $result->getQueryEnd() . " "
              . $seqID . "\n";
        }

        $repeatsMasked++;
      }

      foreach my $idKey ( keys( %maskRanges ) ) {
        $idsSeen{$idKey} = 1;
        print OUT ">" . $idKey . " " . $maskDB->getDescription( $idKey ) . "\n";
        my $seq = $maskDB->getSequence( $idKey );
        foreach my $range ( @{ $maskRanges{$idKey} } ) {
          print "      - Masking $idKey, $range->[0] - " . "$range->[1]\n"
              if ( $DEBUG );
          substr( $seq, $range->[ 0 ], $range->[ 1 ] ) = "N" x $range->[ 1 ];
        }
        $seq =~ s/(.{50})/$1\n/g;
        print OUT "$seq\n";
      }

      # Clear memory
      %maskRanges = ();
      undef $resultCollection;
    }    # else
  }    # for

  # Write out any records which didn't have any masking
  foreach my $idKey ( $maskDB->getIDs() ) {
    next if ( exists $idsSeen{$idKey} );
    print OUT ">" . $idKey . " " . $maskDB->getDescription( $idKey ) . "\n";
    my $seq = $maskDB->getSequence( $idKey );
    $seq =~ s/(.{50})/$1\n/g;
    print OUT "$seq\n";
  }
  close OUT;
  close $INST if ( defined $INST );
  undef $maskDB;

  if ( $repeatsMasked == 0 ) {
    unlink( "$fastaFile.masked" );
    unlink( "$parameters{'instSeqFile'}" )
        if ( defined $parameters{'instSeqFile'}
             && -z $parameters{'instSeqFile'} );
  }
  unlink( "$dbName.xns" );
  unlink( "$dbName.xnt" );
  unlink( "$dbName.xni" );
  unlink( "$dbName.xnd" );

  return $repeatsMasked;

}

##---------------------------------------------------------------------##

=head2 wublastMaskDatabase()

  Use: wublastMaskDatabase( xdformatPath => "/usr/local/wublast/xdformat",
                     fastaFile => "/jo/bob/seq.fa",
                     consensi => "/jo/bob/lib/reps.fa",
                     searchEngine => $searchEngine,
                     [instSeqFile => "/jo/bob/instances.out"] );

=cut

##---------------------------------------------------------------------##
sub wublastMaskDatabase {
  my %parameters = @_;

  # Parameter checking
  die $CLASS
      . "::maskDatabase(): Missing or invalid xdformatPath "
      . "parameter!\n"
      if (    !defined $parameters{'xdformatPath'}
           || !-x $parameters{'xdformatPath'} );
  my $xdformatPath = $parameters{'xdformatPath'};

  die $CLASS . "::maskDatabase(): Missing fastaFile parameter!\n"
      if (    !defined $parameters{'fastaFile'}
           || !-s $parameters{'fastaFile'} );
  my $fastaFile = $parameters{'fastaFile'};
  my $tempDir   = dirname( $fastaFile );

  die $CLASS . "::maskDatabase(): Missing consensi parameter!\n"
      if (    !defined $parameters{'consensi'}
           || !-s $parameters{'consensi'} );
  my $consensi = $parameters{'consensi'};

  die $CLASS . "::maskDatabase(): Missing searchEngine parameter!\n"
      if ( !defined $parameters{'searchEngine'} );
  my $searchEngine = $parameters{'searchEngine'};

  my $instSeqFile;
  $instSeqFile = $parameters{'instSeqFile'}
      if ( defined $parameters{'instSeqFile'} );

  # Setup the temporary database
  my $index     = 1;
  my $xdfDBName = "tmpMaskDB-$index";
  while ( -s "$xdfDBName.xns" ) {
    $index++;
    $xdfDBName = "tmpMaskDB-$index";
  }
  my $tmpDBStats  = `$xdformatPath -n -I -o $xdfDBName $fastaFile 2>&1`;
  my $dbNumSeqs   = 0;
  my $dbMaxSeqLen = 0;
  foreach my $line ( split /[\n\r]+/, $tmpDBStats ) {
    if ( $line =~ /No. of sequences \(letters\) written:\s*([\d,]+)/ ) {
      $dbNumSeqs = $1;
      $dbNumSeqs =~ s/,//g;
      next;
    }
    if ( $line =~ /Longest sequence written \(in database\):\s*([\d,]+)/ ) {
      $dbMaxSeqLen = $1;
      $dbMaxSeqLen =~ s/,//g;
      last;
    }
  }
  my $maxBatchSize = 100;
  my $batchSize    = 5;
  print $CLASS
      . "::maskDatabase(): tmpDBName = $xdfDBName size = $dbNumSeqs"
      . " longest sequence size = $dbMaxSeqLen batchSize = $batchSize\n"
      if ( $DEBUG );

  # TODO: Consider using xdget instead of this
  my $maskDB = FastaDB->new( fileName => $fastaFile,
                             openMode => SeqDBI::ReadOnly );
  open OUT, ">$fastaFile.masked";

  # Setup the Query/Subject
  $searchEngine->setQuery( $consensi );
  $searchEngine->setSubject( $xdfDBName );
  $searchEngine->setTempDir( $tempDir );

  my $INST;
  if ( defined $parameters{'instSeqFile'} ) {
    open $INST, ">$parameters{'instSeqFile'}";
  }

  # Check to make sure additional parameters haven't already
  # been set
  my $additionalParams = "";
  $additionalParams = $searchEngine->getAdditionalParameters();
  $additionalParams = "" if ( !defined $additionalParams );

  my $repeatsMasked = 0;
  my %idsSeen       = ();
  for ( my $i = 1 ; $i <= $dbNumSeqs ; $i += $batchSize ) {
    my $dbEnd = $i + $batchSize - 1;
    $dbEnd = $dbNumSeqs if ( $dbEnd > $dbNumSeqs );
    print "   - Masking $i - $dbEnd of $dbNumSeqs\n";

    $searchEngine->setAdditionalParameters(
                     "$additionalParams dbslice=" . $i . "-$dbEnd/$dbNumSeqs" );

    my ( $status, $resultCollection ) = $searchEngine->search();
    if ( $status ) {
      print STDERR "\nERROR from search engine (", $? >> 8, ") \n";
    }
    elsif ( $resultCollection->size() > 0 ) {

      if ( $resultCollection->size() < 500000 ) {
        $batchSize += 10;
        $batchSize = $maxBatchSize if ( $batchSize > $maxBatchSize );

        #print "Raising batch size to $batchSize, resultColl size = " .
        #      $resultCollection->size() . "\n";
      }

      print "    -- Collecting " . $resultCollection->size() . " ranges...\n"
          if ( $DEBUG );
      my %maskRanges = ();
      my $seqID;

      for ( my $k = 0 ; $k < $resultCollection->size() ; $k++ ) {

        $seqID = $resultCollection->get( $k )->getSubjName();
        my $startIncr   = 0;
        my $endIncr     = 0;
        my $globalSeqID = $seqID;
        if ( $seqID =~ /(\S+)_(\d+)-\d+$/ ) {
          $globalSeqID = $1;
          $startIncr   = $2;
          $endIncr     = $2;
        }

        my $result     = $resultCollection->get( $k );
        my $start      = $result->getSubjStart();
        my $end        = $result->getSubjEnd();
        my $rangeStart = $start - 1;
        my $rangeEnd   = ( $end - $start + 1 );
        push @{ $maskRanges{$seqID} }, [ $rangeStart, $rangeEnd ];

        # Adjust to global coords
        $start += $startIncr;
        $end   += $endIncr;

        # Store the minus strand hits with reverse index notation
        if ( $result->getOrientation() eq "C" ) {
          my $tmp = $start;
          $start = $end;
          $end   = $tmp;
        }

        if ( defined $INST ) {
          print $INST ""
              . $result->getScore . " "
              . $result->getQueryName() . " "
              . "$globalSeqID $start $end "
              . $result->getQueryStart() . " "
              . $result->getQueryEnd() . " "
              . $result->getSubjName() . "\n";
        }

        $repeatsMasked++;
      }

      foreach my $idKey ( keys( %maskRanges ) ) {
        $idsSeen{$idKey} = 1;
        print OUT ">" . $idKey . " " . $maskDB->getDescription( $idKey ) . "\n";
        my $seq = $maskDB->getSequence( $idKey );
        foreach my $range ( @{ $maskRanges{$idKey} } ) {
          print "      - Masking $seqID, $range->[0] - " . "$range->[1]\n"
              if ( $DEBUG );
          substr( $seq, $range->[ 0 ], $range->[ 1 ] ) = "N" x $range->[ 1 ];
        }
        $seq =~ s/(.{50})/$1\n/g;
        print OUT "$seq\n";
      }

      # Clear memory
      %maskRanges = ();
      undef $resultCollection;
    }    # else
  }    # for

  # Write out any records which didn't have any masking
  foreach my $idKey ( $maskDB->getIDs() ) {
    next if ( exists $idsSeen{$idKey} );
    print OUT ">" . $idKey . " " . $maskDB->getDescription( $idKey ) . "\n";
    my $seq = $maskDB->getSequence( $idKey );
    $seq =~ s/(.{50})/$1\n/g;
    print OUT "$seq\n";
  }
  close OUT;
  close $INST if ( defined $INST );
  undef $maskDB;

  if ( $repeatsMasked == 0 ) {
    unlink( "$fastaFile.masked" );
    unlink( "$parameters{'instSeqFile'}" )
        if ( defined $parameters{'instSeqFile'}
             && -z $parameters{'instSeqFile'} );
  }
  unlink( "$xdfDBName.xns" );
  unlink( "$xdfDBName.xnt" );
  unlink( "$xdfDBName.xni" );
  unlink( "$xdfDBName.xnd" );

  return $repeatsMasked;

}

##---------------------------------------------------------------------##

=head2 gatherInstances()

  Use: { conID => [ { 'score' => #, 
                      'fastaID' => "id", 
                      'start' => #, 
                      'end' => # }, ... ],
          ... } = gatherInstances( fastaFile => "/jo/bob/seq.fa",
                                   consensi => "/jo/bob/lib/reps.fa",
                                   maxInstances => # );

  gatherInstances searches
=cut

##---------------------------------------------------------------------##
sub gatherInstances {
  my %parameters = @_;

  # Parameter checking
  die $CLASS . "::gatherInstances(): Missing fastaFile parameter!\n"
      if (    !defined $parameters{'fastaFile'}
           || !-s $parameters{'fastaFile'} );
  my $fastaFile = $parameters{'fastaFile'};
  my $tempDir   = dirname( $fastaFile );

  die $CLASS . "::gatherInstances(): Missing consensi parameter!\n"
      if (    !defined $parameters{'consensi'}
           || !-s $parameters{'consensi'} );
  my $consensi = $parameters{'consensi'};

  my $tmpCons = "$tempDir/inst-cons-1.fa";
  system( "cp $consensi $tmpCons" );

  my $cdb = FastaDB->new( fileName => $consensi,
                          openMode => SeqDBI::ReadOnly );

  my $searchEngineN =
      WUBlastSearchEngine->new( pathToEngine => $WUBLASTN_PRGM );
  $searchEngineN->setMatrix(
                    "$FindBin::RealBin/Matrices/wublast/nt/comparison.matrix" );
  print
"Setting matrix to : $FindBin::RealBin/Matrices/wublast/nt/comparison.matrix\n";
  $searchEngineN->setMinScore( 250 );
  $searchEngineN->setMaskLevel( 80 );
  $searchEngineN->setGenerateAlignments( 0 );
  $searchEngineN->setGapInit( -25 );
  $searchEngineN->setInsGapExt( -5 );
  $searchEngineN->setDelGapExt( -5 );
  $searchEngineN->setMinMatch( 7 );
  $searchEngineN->setScoreMode( SearchEngineI::complexityAdjustedScoreMode );

  my $fdb = FastaDB->new( fileName => $fastaFile,
                          openMode => SeqDBI::ReadOnly );
  my $fdbBatcher = SimpleBatcher->new( $fdb, 1000000, 0 );

  my %instances  = ();
  my %removeHash = ();
  for ( my $i = 1 ; $i <= $fdbBatcher->getBatchCount ; $i++ ) {
    print "Writing $tempDir/inst-db-$i.fa\n";
    $fdbBatcher->writeBatchFile( $i, "$tempDir/inst-db.fa" );

    system(
      "$XDFORMAT_PRGM -n -I " . "$tmpCons >> " . "$tempDir/xdformat.log 2>&1" );

    $searchEngineN->setQuery( "$tempDir/inst-db.fa" );
    $searchEngineN->setSubject( "$tmpCons" );

    print "Searching..\n";
    my ( $status, $resultCollection ) = $searchEngineN->search();
    if ( $status ) {
      print STDERR "\nERROR from search engine (", $? >> 8, ") \n";
    }
    else {
      for ( my $k = 0 ; $k < $resultCollection->size() ; $k++ ) {
        my $resultRef = $resultCollection->get( $k );
        my $consID    = $resultRef->getSubjName();
        if ( defined $instances{$consID} ) {

         #print "Instances for $consID = " . $#{ $instances{ $consID } } . "\n";
          if ( $#{ $instances{$consID} } < 1000 ) {
            push @{ $instances{$consID} },
                {
                  'score'   => $resultRef->getScore(),
                  'fastaID' => $resultRef->getQueryName(),
                  'start'   => $resultRef->getQueryStart(),
                  'end'     => $resultRef->getQueryEnd()
                };
          }
          else {
            $removeHash{$consID} = 1;
          }
        }
        else {
          push @{ $instances{$consID} },
              {
                'score'   => $resultRef->getScore(),
                'fastaID' => $resultRef->getQueryName(),
                'start'   => $resultRef->getQueryStart(),
                'end'     => $resultRef->getQueryEnd()
              };
        }
      }
      if ( keys( %removeHash ) ) {
        open OUT, ">$tmpCons";
        my $numSeqs = 0;
        foreach my $seqID ( $cdb->getIDs() ) {
          next if ( defined $removeHash{$seqID} );
          print OUT ">$seqID\n";
          print OUT "" . $cdb->getSequence( $seqID ) . "\n";
          $numSeqs++;
        }
        close OUT;
        print "$numSeqs Consensi Remaining\n";
        last if ( !$numSeqs );
      }
    }
    undef $resultCollection;
  }
  unlink( $tmpCons );
  unlink( "$tempDir/inst-db.fa" );
  unlink( "$tempDir/inst-db.fa.xns" );
  unlink( "$tempDir/inst-db.fa.xnt" );
  unlink( "$tempDir/inst-db.fa.xni" );
  unlink( "$tempDir/inst-db.fa.xnd" );

  return ( \%instances );
}


#
# A helper function to open an input file, identify it as either a
#   "linup" =  Linup *.ali file
#   "msa-fasta" =  MSA file in FASTA format
#   "stockholm" =  Stockholm file
#   "malign" =  A *.malign file
#   "crossmatch" =  A crossmatch-like *.out file of one sequence vs many
#
# And return a fully populated MultAln object.
#
sub openAsMultAln{
  my $inputFile = shift;
  
  open IN, "<$inputFile" or die "openAsMultAln(): Could not open $inputFile for reading!\n";
  my $maxLines = 10000;
  my $fileType = "Unknown";
  my $foundFastaHdr = 0;
  my $foundConsensusHdr = 0;
  while ( <IN> )
  {
    next if (    /^\s*$/ 
              || /^(\W+).*Score:/ );
    last if ( $maxLines-- < 0 );
    if ( /^#\s+STOCKHOLM/ )
    {
      $fileType = "stockholm";
      last;
    }
    if ( /^\s*\d+\s+[\d\.]+\s+[\d\.]+\s+[\d\.]+\s+\S+\s+\d+\s+\d+\s+\(\d+\)/ ||
         /Score:\s+\d+\s+Residues:/ )
    {
      # The second case is a check for a crossmatch file that has lots of binary
      # log entries preceeding the first alignment.
      $fileType = "crossmatch";
      last;
    }
    if ( /^consensus\s+\d+\s+\S+\s+\d+\s*$/ ) {
      $foundConsensusHdr = 1;
    }
    if ( $foundConsensusHdr && /^ref:/ ) {
      $fileType = "linup";
      last;
    }
    $foundFastaHdr = 1 if ( /^>\S+.*/ );
    if ( $foundFastaHdr && /^\s*[ACGTUMRWSYKVHDBNacgtumrwsykvhdbn\-\.]+\s*$/ )
    {
      $fileType = "msa-fasta";
      last;
    }
    if ( /^\s+\'alignCol\'\s+=>/ )
    {
      $fileType = "malign";
      last;
    }
      
  }
  close IN;
  
  if ( $fileType eq "Unknown" )
  {
    die "openAsMultAln(): Could not determine filetype for $inputFile.  Verify that\n"
        . "the file is either a cross_match, stockholm or an msa-fasta file.\n";
  }
  
  my $mAlign;
  my $seedAlign;
  if ( $fileType eq "crossmatch" )
  {
    my $resultCollection =
        CrossmatchSearchEngine::parseOutput( searchOutput => $inputFile );
  
    # TODO: Deprecate this and move it to SearchResultCollection.pm
    # Auto detect which input ( query/subject ) is the static sequence for
    # which all other sequences are aligned.
    my $queryID;
    my $subjID;
    my $staticQuery   = 1;
    my $staticSubject = 1;
    for ( my $i = 0 ; $i < $resultCollection->size() ; $i++ )
    {
      my $result = $resultCollection->get( $i );
      my $qID    = $result->getQueryName();
      my $sID    = $result->getSubjName();
      $staticQuery   = 0 if ( defined $queryID && $queryID ne $qID );
      $staticSubject = 0 if ( defined $subjID  && $subjID  ne $sID );
      die "openAsMultAln(): Strange...this appears not to be a multiple alignment!"
          if ( $staticQuery == 0 && $staticSubject == 0 );
      $queryID = $qID;
      $subjID  = $sID;
    }
    die "openAsMultAln(): Could not determine reference sequence.  This doesn't look like\n"
        . "a multiple alignment to one reference sequence!\n"
        if ( $staticQuery && $staticSubject );
  
    my $refInput = MultAln::Subject;
    $refInput = MultAln::Query if ( $staticQuery );
  
    $mAlign = MultAln->new(
                          referenceSeq              => "",
                          searchCollection          => $resultCollection,
                          searchCollectionReference => $refInput
                           );
  } elsif ( $fileType eq "stockholm" )
  {
    open my $IN, "<$inputFile" or die "openAsMultAln(): Could not open $inputFile for reading";
    $seedAlign = SeedAlignment->new();
    $seedAlign->read_stockholm( $IN );
    close $IN;
    $mAlign = MultAln->new( seedAlignment => $seedAlign );
  }elsif ( $fileType eq "msa-fasta" )
  { 
    my @seqs;
    my $seq;
    my $id;
    open my $IN, "<$inputFile" or die "openAsMultAln(): Could not open $inputFile for reading";
    # Simple FASTA reader
    my %idHash = ();
    while (<$IN>) {
      if ( /^>(\S+)/ ) 
      {
        my $tmpID = $1;
        if ( defined $idHash{$tmpID} ) {
          my $ver = 1;
          while ( defined $idHash{$tmpID . "_$ver"} ) 
          {
            $ver++;
          }
          warn "openAsMultAln(): WARN File contains a duplicate identifier \"$tmpID\".  A suffix of \"_$ver\"\n" .
               "                      will be appended to this occurence.\n";
          $tmpID = $tmpID . "_$ver";
        }
        $idHash{$tmpID}++;
        if ( $seq )
        {
          $seq = uc($seq);
          # Convert prefix/suffix "-"s to spacers
          if ( $seq =~ /^(\-+)/ ){
            substr($seq,0,length($1)) = " "x(length($1));
          }
          if ( $seq =~ /(\-+)$/ ) {
            substr($seq,length($seq)-length($1)-1) = " "x(length($1));
          }
          push @seqs, [ $id, $seq ];
        }
        $seq = "";
        $id = $tmpID;
        next;
      }
      s/[\s\n\r]+//g;
      $seq .= $_;
    }
    if ( $seq )
    {
      # Convert prefix/suffix "-"s to spacers
      if ( $seq =~ /^(\-+)/ ){
        substr($seq,0,length($1)) = " "x(length($1));
      }
      if ( $seq =~ /(\-+)$/ ) {
        substr($seq,length($seq)-length($1)-1) = " "x(length($1));
      }
   
      $seq = uc($seq);
      push @seqs, [ $id, $seq ];
    }
    close $IN;
    $mAlign = MultAln->new( sequences => \@seqs );
  }elsif ( $fileType eq "malign" ){
    $mAlign = MultAln->new();
    $mAlign = $mAlign->serializeIN( $inputFile );
  }elsif ( $fileType eq "linup" ) {
    open my $IN, "<$inputFile" or die "openAsMultAln(): Could not open $inputFile for reading";
    # Linup format
    my %seqHash = ();
    my $blockLen = 0;
    my $alignCols = 0;
    my $blockNumber = 0;
    while (<$IN>) {
      next if ( /^ref:/ );
      if ( /^consensus\s+\d+\s+(\S+)/ ){
        $blockNumber++;
        $blockLen = length($1);
        $alignCols += $blockLen;
        next;
      }
      if ( /^(\S+)\s+(\d+)\s+(\S+)\s+(\d+)\s*$/ ) 
      {
        # Traditional Linup reporting format file!
        # For several reasons this format is not easily
        # parsed.
        croak "RepeatUtil::openAsMultAln(): This Linup report file is in a legacy format and\n" .
              "cannot be opened as MultAln object.  The newer format has an additional column\n" .
              "specifying a line identifier.  Please regenerate this file using a newer version\n" .
              "of Linup.\n";
      }
      if ( /^(\S+)\s+(\d+)\s+(\S+)\s+(\d+)\s+\[(\d+)\]$/ ) 
      {
        my $id = $1;
        my $start = $2;
        my $seq = $3;
        my $end = $4;
        my $lineID = $5;
        warn "openAsMultAln(): Oops end is less than start ( $start - $end )\n" if ( $end < $start );
        if ( exists $seqHash{$lineID} ) {
          $seqHash{$lineID}->{'start'} = $start if ( $seqHash{$lineID}->{'start'} > $start );
          $seqHash{$lineID}->{'end'} = $start if ( $seqHash{$lineID}->{'end'} < $end );
          my $gapPadding = "-"x($blockLen*($blockNumber-$seqHash{$lineID}->{'lastblock'}-1));
          $seqHash{$lineID}->{'seq'} .= $gapPadding . $seq;
        }else {
          $seqHash{$lineID} = {};
          $seqHash{$lineID}->{'id'} = $id;
          $seqHash{$lineID}->{'start'} = $start;
          $seqHash{$lineID}->{'end'} = $start;
          $seqHash{$lineID}->{'seq'} = ' 'x($alignCols-length($seq)) . $seq;
          $seqHash{$lineID}->{'lastblock'} = $blockNumber;
        }
      }
    }
    my @seqs;
    foreach my $lineID ( keys %seqHash ) {
      my $id = $seqHash{$lineID}->{'id'};
      my $seq = $seqHash{$lineID}->{'seq'};
      my $start = $seqHash{$lineID}->{'start'};
      my $end = $seqHash{$lineID}->{'end'};
      my $len = $end - $start + 1;
      $seq =~ s/[-\s]/\./g;
      #if ( $id =~ /(\S+)\:(\d+)-(\d+)/ ) {
      #  my $newStart;
      #  my $newEnd;
      #  my $newID;
      #  if ( $2 > $3 ) {
      #    # Reverse
      #    $newStart = $2 - $start + 1;
      #    $newEnd = $newStart - ( $len );
      #  }else {
      #    $newStart = $2 + $start - 1;
      #    $newEnd = $newStart + ( $len );
      #  }
      #  $newID = $1 . ":" . $newStart . "-" . $newEnd;
      #  $id = $newID;
      #}
      push @seqs, [ $id, $seq ];
    }
    $mAlign = MultAln->new( sequences => \@seqs );
  }else {
    die "openAsMultAln(): Support for $fileType is not complete yet ";
  }
  return($mAlign, $fileType);
}


1;





1;
