#!/usr/bin/perl -w
# Copyright (c) 2011 Daneel S. Yaitskov <rtfm.rtfm.rtfm@gmail.com.>. 

# All rights reserved.
# This program is free software; you can redistribute it and/or
# modify it under the same terms as Perl itself.

# turbo-ftp-sync - a script moves changes of files and folders of a local
# machine to a remote one via FTP very fast with minimum network traffic.

use strict;
use warnings;
use Exception::Class::Base;
use Exception::Class::TryCatch;
use Exception::Class (
    'FileNotFound' => { fields => [ 'fileName' ] },
    'NetWorkEx', # something wrong with server or netlink
    'PrgBug' # the exception is purposed to indicate the program encountered with a bug
    );
use File::Find;
use File::Listing;
use Net::FTP;
use Net::Cmd;
use Cwd;
use Net::Netrc;
use IO::Handle;

my $VERSION = 0.5;

package PrgOpts;
# singleton :)
our $theOpts = undef;

sub new {
    my ($class, $argv ) = @_;
    my $self = {
        dbh=>undef,
        newDB=>0,
        dbpath=>"",
        uildDB=>0,
        nodelete=>0,
        returncode=>0,
        configfile=>$ENV{"HOME"}."/.turbo-ftp-sync",
        # basics
        localdir=>"",
        remoteURL=>"",
        ftpuser=>"anonymous",
        ftppasswd=>"anonymos",
        ftpserver=>"localhost",
        ftpdir=>"",
        maxerrors=> 3, 
        ftptimeout=>120,
        # verbosity
        doverbose=>1,
        dodebug=>0,
        doquiet=>0,
        doinfoonly=>0,
        infotext=>"",
        docheckfirst=>0,
        ignoremask => "",
        followsymlinks=>0,
        doflat=>0,
    };
    bless $self, $class;
    $self->parseCommandLineParameters( $argv );
    return $self;
}

# return cfgfoptions
sub readConfigFile {
    my ( $self ) = @_;
    my @cfgfoptions=();
    if ($self->{configfile} ne "") {
        if (-r $self->{configfile}) {
            #print "Reading config file.\n"; # For major problem debugging
            open (CONFIGFILE,"<$self->{configfile}");
            while (<CONFIGFILE>) {
                $_ =~ s/([ 	\n\r]*$|\.\.|#.*$)//gs;
                if ($_ eq "") { next; }
                if ( ($_ =~ /[^=]+=[^=]+/) || ($_ =~ /^-[a-zA-Z]+$/) ) { push @cfgfoptions, $_; }
            }
            close (CONFIGFILE);
        } # else { print "Config file does not exist.\n"; } # For major problem debugging
    } # else { print "No config file to read.\n"; } # For major problem debugging
    return \@cfgfoptions;
}

sub print_options() {
    my ( $self ) = @_;
    print "\nPrinting options:\n";
    # meta
    print "returncode    = ", $self->{returncode}    , "\n";
    print "configfile    = ", $self->{configfile}    , "\n";
    # basiscs
    print "localdir      = ", $self->{localdir}      , "\n";
    # FTP stuff
    print "remoteURL     = ", $self->{remoteURL}     , "\n";
    print "ftpuser       = ", $self->{ftpuser}       , "\n";
    print "ftppasswd     = ", $self->{ftppasswd}     , "\n";
    print "ftpserver     = ", $self->{ftpserver}     , "\n";
    print "ftpdir        = ", $self->{ftpdir}        , "\n";
    # verbsityosity
    print "doverbose     = ", $self->{doverbose}     , "\n";
    print "dodebug       = ", $self->{dodebug}       , "\n";
    print "doquiet       = ", $self->{doquiet}       , "\n";
    #  print "db       = ", $dbh       , "\n";  
    #
    print "doinfoonly    = ", $self->{doinfoonly}    , "\n";
    print "\n";
}

sub print_syntax() {
    print "\n";
    print "turbo-ftp-sync.pl $VERSION (2011-05-12)\n";
    print "author is Daneel S. Yaitskov ( rtfm.rtfm.rtfm\@gmail.com )\n";    
    print "\n";
    print " turbo-ftp-sync [ options ] [ localdir remoteURL ]\n";
    print " options = [-dfgpqv] [ cfg|ftpuser|ftppasswd|ftpserver|ftpdir=value ... ] \n";
    print "   localdir    local directory, defaults to \".\".\n";
    print "   remoteUrl   full FTP URL, scheme\n";
    print '               ftp://[ftpuser[:ftppasswd]@]ftpserver/ftpdir'."\n";
    print "               ftpdir is relative, so double / for absolute paths as well as /\n";
    print "   -c | -C     like -i, but then prompts whether to actually do work\n";
    print "   -d | -D     turns debug output (including verbose output) on\n";
    print "   -f | -F     flat operation, no subdir recursion\n";
    print "   -h | -H     prints out this help text\n";
    print "   -i | -I     forces info mode, only telling what would be done\n";
    print "   -n | -N     no deletion of obsolete files or directories\n";
    print "   -l | -L     follow local symbolic links as if they were directories\n";
    print "   -q | -Q     turns quiet operation on\n";
    print "   -b | -B     build DB only - i.e don't upload data to remote host\n";  
    print "   -v | -V     turnes verbose output on\n";
    print "   maxerrors=  if not 0 then program exit with nonzero code.\n";     
    print "   cfg=        read parameters and options from file defined by value.\n";
    print "   ftpserver=  defines the FTP server, defaults to \"localhost\".\n";
    print "   ftpuser=    defines the FTP user, defaults to \"ftp\".\n";
    print "   db=         defines the file where info about uploaded files is stored.\n";  
    print "   ftppasswd=  defines the FTP password, defaults to \"anonymous\".\n";
    print "   ignoremask= defines a regexp to ignore certain files, like .svn"."\n";
    print "\n";
    print " Later mentioned options and parameters overwrite those mentioned earlier.\n";
    print " Command line options and parameters overwrite those in the config file.\n";
    print " Don't use '\"', although mentioned default values might motiviate you to.\n";
    print "\n";
    print " If ftpuser or ftppasswd resovle to ? (no matter through which options),\n";
    print " turbo-ftp-sync.pl asks you for those interactively.\n";
    print "\n";
    print " PROGRAM CAN UPLOAD CHANGES ONLY IN ONE DIRECTION\n";
    print " FROM YOUR MACHINE TO REMOTE MACHINE.\n";
    print " ALSO PROGRAM CANNOT KNOW ABOUT CHANGES WERE MADE ON A REMOTE MACHINE.\n";        
    print "\n";
    print " Demo usage: turbo-ftp-sync.pl db=db.db webroot ftp://yaitskov:secret\@ftp.vosi.biz//\n";        
    print "\n";    
}

sub parseParameters {
    my ( $self, $curopt ) = @_;
    $self->{noofopts}++;
    my ($fname, $fvalue) = split /=/, $curopt, 2;
    if    ($fname eq "cfg")       { return; }
    elsif ($fname eq "ftpdir") {
        $self->{ftpdir}     =$fvalue;
        if ($self->{ftpdir} ne "/") { $self->{ftpdir}=~s/\/$//; }
    }
    elsif ($fname =~ m/ftppass(w(or)?d)?/i) {
        $self->{ftppasswd}=$fvalue;
    }
    elsif ($fname eq "ftpserver") {
        $self->{ftpserver}  =$fvalue;
    }
    elsif ($fname eq "ftpuser")   {
        $self->{ftpuser}    =$fvalue;
    }elsif ( $fname eq "maxerrors" ){
        if ( $fvalue =~ /^[0-9]{1,3}$/ ){
            $self->{maxerrors} = $fvalue;
        }else {
            $self->{returncode} += 1;
            print STDERR "maxerrors must non-negative integer but got: '$fvalue'\n" ;
        }
    }elsif ($fname eq "localdir")  {
        $self->{localdir}   =$fvalue; $self->{localdir}=~s/\/$//;
    }
    elsif ($fname eq "timeout")   { if ($fvalue>0) { $self->{ftptimeout} =$fvalue; } }
    elsif ($fname eq "ignoremask") { $self->{ignoremask} = $fvalue; }
    elsif ($fname eq "db" ){
        $self->{dbpath} = $fvalue;
    }
}
sub parseFtpParameter {
    my ( $self, $curopt ) = @_;
    $self->{noofopts}++;
    $self->{remoteURL} = $curopt;
    $self->parseRemoteURL();
}
sub parseRemoteURL() {
    my ( $self ) = @_;
    if ($self->{remoteURL} =~ /^ftp:\/\/(([^@\/\\\:]+)(:([^@\/\\\:]+))?@)?([a-zA-Z01-9\.\-]+)\/(.*)/) {
        #print "DEBUG: parsing ".$remoteURL."\n";
        #print "match 1 = ".$1."\n";
        #print "match 2 = ".$2."\n";
        #print "match 3 = ".$3."\n";
        #print "match 4 = ".$4."\n";
        #print "match 5 = ".$5."\n";
        #print "match 6 = ".$6."\n";
        #print "match 7 = ".$7."\n";
        if (length($2) > 0) { $self->{ftpuser}   = $2; }
        if (length($4) > 0) { $self->{ftppasswd} = $4; }
        $self->{ftpserver} = $5;
        $self->{ftpdir} = $6;
        if ($self->{ftpdir} ne "/") { $self->{ftpdir}=~s/\/$//; }
    }
}

sub parseOptions {
    my ( $self, $curopt ) = @_;
    my $i;
    for ($i=1; $i < length($curopt); $i++) {
        my $curoptchar = substr ($curopt, $i, 1);
        $self->{noofopts}++;
        if    ($curoptchar =~ /[cC]/)  { $self->{docheckfirst}=1; }
        elsif ($curoptchar =~ /[dD]/)  { $self->{dodebug}=1; $self->{doverbose}=3; $self->{doquiet}=0; }
        elsif ($curoptchar =~ /[fF]/)  { $self->{doflat}=1; }
        elsif ($curoptchar =~ /[hH?]/) { $self->print_syntax(); exit 0; }
        elsif ($curoptchar =~ /[iI]/)  { $self->{doinfoonly}=1; }
        elsif ($curoptchar =~ /[lL]/)  { $self->{followsymlinks}=1; }
        elsif ($curoptchar =~ /[qQ]/)  { $self->{dodebug}=0; $self->{doverbose}=0; $self->{doquiet}=1; }
        elsif ($curoptchar =~ /[vV]/)  { $self->{doverbose}++; }
        elsif ($curoptchar =~ /[nN]/)  { $self->{nodelete}=1; }
        elsif ($curoptchar =~ /[bB]/) { $self->{buildDB} = 1 ; }
        else  { print "ERROR: Unknown option: \"-".$curoptchar."\"\n"; $self->{returncode}+=1; }
    }    
}
sub parseLocalDir {
    my ( $self, $curopt ) = @_;
    if ($self->{localdir} eq "") {
        $self->{noofopts}++;
        $self->{localdir} = $curopt;
    } else {
        print "ERROR: Unknown parameter: \"".$curopt."\"\n"; $self->{returncode}+=1
    }    
}
# function has side effect; return nothing
# it changes variables of current package
sub parseOptionsAndParameters {
    my ( $self, $cfgfoptions, $cloptions ) = @_;
    $self->{noofopts}=0;
    for my $curopt (@$cfgfoptions, @$cloptions) {
        if ($curopt =~ /^-[a-zA-Z]/) {
            $self->parseOptions( $curopt );
        }
        elsif ($curopt =~ /^ftp:\/\/(([^@\/\\\:]+)(:([^@\/\\\:]+))?@)?([a-zA-Z01-9\.\-]+)\/(.*)/) {
            $self->parseFtpParameter ( $curopt );
        }
        elsif ($curopt =~ /^[a-z]+=.+/) {
            $self->parseParameters ( $curopt );
        }
        else {
            $self->parseLocalDir ( $curopt );
        }
    }
    if (0 == $self->{noofopts}) { $self->print_syntax(); exit 0; }    
}
sub parseCfg {
    my ( $self, $argv ) =  @_ ;
    my @cloptions=();
    for my $curopt (@ARGV) {
        if ($curopt =~ /^cfg=/) {
            $self->{configfile}="$'";
            if (! -r $self->{configfile}) {
                print "Config file does not exist: "
                    . $self->{configfile} . "\n";
                $self->{returncode} += 1;
            }
        } else {
            push @cloptions, $curopt;
        }
    }    
    return \@cloptions;
}
sub netRC {
    my ( $self ) = @_;
    if ( ($self->{ftpserver} ne "") and ($self->{ftppasswd} eq "anonymous") ) {
        if ($self->{ftpuser} eq "ftp") {
            my $netrcdata = Net::Netrc->lookup($self->{ftpserver});
            if ( defined $netrcdata ) {
                $self->{ftpuser} = $netrcdata->login;
                $self->{ftppasswd} = $netrcdata->password;
            }
        } else { 
            my $netrcdata = Net::Netrc->lookup($self->{ftpserver},$self->{ftpuser});
            if ( defined $netrcdata ) {
                $self->{ftppasswd} = $netrcdata->password;
            }
        }
    }            
}
sub validateFtp {
    my ( $self ) = @_;
    if ($self->{ftpuser}   eq "?") { print "User: ";     $self->{ftpuser}=<STDIN>;   chomp($self->{ftpuser});   }
    if ($self->{ftppasswd} eq "?") { print "Password: "; $self->{ftppasswd}=<STDIN>; chomp($self->{ftppasswd}); }
    if ($self->{ftpserver} eq "") { print "ERROR: No FTP server given.\n"; $self->{returncode}+=1; }
    if ($self->{ftpdir}    eq "") { print "ERROR: No FTP directory given.\n"; $self->{returncode}+=1; }
    if ($self->{ftpuser}   eq "") { print "ERROR: No FTP user given.\n"; $self->{returncode}+=1; }
    if ($self->{ftppasswd} eq "") { print "ERROR: No FTP password given.\n"; $self->{returncode}+=1; }    
}

sub parseCommandLineParameters {
    my ( $self, $argv ) = @_;
    my $cloptions = $self->parseCfg ( $argv );
    my $cfgfoptions = $self->readConfigFile ();
    $self->parseOptionsAndParameters( $cfgfoptions, $cloptions );
    if ( $self->{dbpath} eq "" ){
        die "Required path to a file with the database (use parameter db=)";
    }
    if ( $self->{dodebug} ) { $self->print_options(); }
    if ( ($self->{localdir}  eq "" ) || (! -d $self->{localdir} ) )  {
        print "ERROR: Local directory does not exist: '$self->{localdir}'\n";
        $self->{returncode}+=1;
    }
    $self->{newDB} = ! -f $self->{dbpath};    
    if ( ! $self->{buildDB} ) {
        $self->netRC();
        $self->validateFtp();
    }
    if ($self->{returncode} > 0) {
        die "Aborting due to missing or wrong options!"
            . "Call turbo-ftp-sync -? for more information.\n";
    }
}

{
    package MyFtp;
    use base qw (Net::FTP);
    sub new () {
        my ( $class, $ftpserver, $doftpdebug, $ftptimeout) = @_;

        my $self = $class->SUPER::new( $ftpserver,
                                       Debug=>$doftpdebug,
                                       Timeout=>$ftptimeout,
                                       Passive=>1 ) ;
        return $self;
    }
    sub setPerms {
        my ( $self, $path, $perms ) = @_;
        $self->quot('SITE', sprintf('CHMOD %04o %s', $perms, $path));
    }
    sub connection() {
        my ( $class ) = @_;
        if ($theOpts->{dodebug}) {
            print "\nFind out if ftp server is online & accessible.\n";
        }
        my $doftpdebug=($theOpts->{doverbose} > 2);
        my $ftpc = MyFtp->new (
            $theOpts->{ftpserver},
            $doftpdebug,
            $theOpts->{ftptimeout}
            ) || die "Could not connect to $theOpts->{ftpserver}\n";
        if ($theOpts->{dodebug}) {
            print "Logging in as $theOpts->{ftpuser} with password $theOpts->{ftppasswd}.\n"
        }
        
        $ftpc->login( $theOpts->{ftpuser},
                      $theOpts->{ftppasswd}
            ) || die "Could not login to $theOpts->{ftpserver} as $theOpts->{ftpuser}\n";
        my $ftpdefdir = $ftpc->pwd();
        if ( $theOpts->{dodebug}) {
            print "Remote directory is now ".$ftpdefdir."\n";
        }
        # insert remote login directory into relative ftpdir specification
        if ( $theOpts->{ftpdir} !~ /^\//) 
        {
            if ($ftpdefdir eq "/")
            {
                $theOpts->{ftpdir} = $ftpdefdir . $theOpts->{ftpdir};
            }else{
                $theOpts->{ftpdir} = $ftpdefdir . "/" . $theOpts->{ftpdir};
            }
            if (!$theOpts->{doquiet}){
                print "Absolute remote directory is $theOpts->{ftpdir}\n";
            }
        }
        if ( $theOpts->{dodebug} ) {
            print "Changing to remote directory $theOpts->{ftpdir}.\n"
        }

        $ftpc->binary()
            or die "Cannot set binary mode ", $ftpc->message;
        $ftpc->cwd($theOpts->{ftpdir})
            or die "Cannot cwd to $theOpts->{ftpdir} ", $ftpc->message;
        if ($ftpc->pwd() ne $theOpts->{ftpdir}) {
            die "Could not change to remote base directory $theOpts->{ftpdir}\n";
        }
        if ($theOpts->{dodebug}) {
            print "Remote directory is now " . $ftpc->pwd() . "\n";
        }
        return $ftpc;
    }
    sub isConnected {
        my ( $self ) = @_;
        # Prepend connection time out while file reading takes
        # longer than the remote ftp time out
        # - 421 Connection timed out.
        # - code=421 or CMD_REJECT=4
        if (!$self->pwd()) {
            # or $self->status == Net::Cmd::CMD_REJECT;
            return $self->code == 421;                
        }
        return 1;
    }
}

# {
#     package MyFtp;
#     use File::Copy;
#     sub new () {
#         my ( $class) = @_;
#         my $self = { rempass => "/tmp/xxx" } ;
#         bless $self, $class;
#         return $self;
#     }
#     sub size {
#         my ( $self, $path ) = @_;
#         my @stat = lstat ( $self->{rempass} . "/$path" );
#         return $stat[7];
#     }
#     sub setPerms {
#         my ( $self, $path, $perms ) = @_;
#         chmod ($perms, $self->{rempass} . "/$path") ;
#     }
#     sub message {
#         return "Message";
#     }
#     sub binary {
#         return 1;
#     }
#     sub connection() {
#         my ( $class ) = @_;
#         return $class->new () ;
#     }
#     sub delete {
#         my ( $self, $path );
#         return unlink ( $path  );
#     }
#     sub mkdir {
#         my ( $self, $path ) = @_;
#         if ( mkdir ( $self->{rempass} . "/$path" ) ){
#             return $path;
#         }
#         return "";
#     }
#     sub put {
#         my ($self, $src, $dst ) = @_;
#         if ( copy ( $src, $self->{rempass} . "/$dst" ) ){
#             return $src;
#         }
#         return "";
#     }
    
#     sub rmdir {
#         my ($self, $path ) = @_;
#         return rmdir( $self->{rempass} . "/$path" );
#     }
        
#     sub ls {
#         my ( $self, $path ) = @_;
#         return $self->dir( $path );
#     }
#     sub dir {
#         my ( $self, $path ) = @_;
#         if ( -d ( $self->{rempass} . "/$path" ) ){
#             return ( wantarray  ? ( ".", ".." )  :   [ ".", ".." ] );
#         }
#         return  ( wantarray  ? @{ [] }  :  [] );        
#     }
#     sub quit {
#         return 1;
#     }
#     sub cwd {
#         return 1;
#     }
#     sub pwd {
#         return shift()->{rempass};        
#     }
#     sub isConnected {
#         return 1;
#     }
# }

{
    package UploadedFiles;
    # a wrapper around a db
    use DBI;
    sub new {
        my ($class, $dbh ) = @_;
        my $self = { dbh => $dbh };
        bless $self, $class;    
        return $self;
    }
    sub selectAllFiles(){
        my ( $self ) = @_;
        return $self->{dbh}->selectall_arrayref(
            'select perms, uploaded as "date", fullname, objsize as "size"'
            . ' from files where objtype = \'f\' order by length(fullname)',
            { Slice => {} }
            );
    }
    sub selectAllDirs(){
        my ( $self ) = @_;
        return $self->{dbh}->selectall_arrayref(
            'select fullname, perms from files where objtype = \'d\' order by length(fullname)',
            { Slice => {} }
            );
    }
    #delete a file or a directory
    sub deleteFile {
        my ($self, $fileName) = @_;
        my $sth = $self->{dbh}->prepare("delete from files where fullname = ?");
        $sth->bind_param( 1, $fileName, DBI::SQL_VARCHAR );
        $sth->execute();        
    }
    sub createDir () {
        my ($self, $dirname, $perms ) = @_;
        my $sth = $self->{dbh}->prepare("insert into files ( objtype, fullname, perms ) values ('d',?,?)" );
        $sth->bind_param ( 1, $dirname, DBI::SQL_VARCHAR );
        $sth->bind_param ( 2, $perms, DBI::SQL_INTEGER );    
        $sth->execute() ;
    }
    sub setPerms() {
        my ( $self, $fileName, $perms ) = @_;
        my $sth = $self->{dbh}->prepare("update files set perms = ? where fullname = ?" );
        $sth->bind_param ( 1, $perms, DBI::SQL_INTEGER );
        $sth->bind_param ( 2, $fileName, DBI::SQL_VARCHAR );        
        $sth->execute();            
    }
    sub uploadFile() {
        my ($self, $fileName, $perms, $date, $size ) = @_ ;
        my $sth = $self->{dbh}->prepare("insert into files ( objtype, fullname, perms, uploaded, objsize ) 
                               values ('f',?,?,?,?)" );    
        $sth->bind_param ( 1, $fileName, DBI::SQL_VARCHAR );
        $sth->bind_param ( 2, $perms, DBI::SQL_INTEGER );
        $sth->bind_param ( 3, $date,  DBI::SQL_INTEGER );
        $sth->bind_param ( 4, $size,  DBI::SQL_INTEGER );    
        $sth->execute();    
    }
    sub getInfo() {
        my ( $self, $fileName ) = @_;
        my $fileinfo = $self->{dbh}->selectrow_arrayref(
            'select uploaded as "date", objsize as "size", perms from files where fullname = ?',
            { Slice => {} },
            $fileName
            );
        return $fileinfo;
    }
    sub reuploadFile (){
        my ($self, $fileName, $perms, $date, $size ) = @_ ;
        my $sth = $self->{dbh}->prepare("update files set perms=?, uploaded=?, objsize=? 
                             where objtype='f' and fullname=?") ;
        $sth->bind_param ( 4, $fileName, DBI::SQL_VARCHAR );    
        $sth->bind_param ( 1, $perms, DBI::SQL_INTEGER );
        $sth->bind_param ( 2, $date,  DBI::SQL_INTEGER );
        $sth->bind_param ( 3, $size,  DBI::SQL_INTEGER );    
        $sth->execute();    
    }
    sub deployScheme () {
        my ($self) = @_;
        $self->{dbh}->do("create table files (fullname text primary key, 
                                          uploaded integer, objtype char, 
                                          objsize integer, perms integer)")
            or die "cannot deploy db scheme";        
    }
}

{
    package FileObject;
    # base class for remote dirs and files and local dirs and files
    sub new {
        my ( $class, $path, $perms ) = @_;
        my $self = { _path => $path, _perms => $perms } ;
        bless $self, $class;
        return $self;
    }
    # return string
    sub getPath {
        my ( $self ) = @_;
        return $self->{_path}; 
    }
    sub setPath {
        my ( $self, $newPath ) = @_;
        $self->{_path} = $newPath;
    }
    # return integer
    sub getPerms {
        my ( $self ) = @_;
        return $self->{_perms}; 
    }
    sub setPerms {
        my ( $self, $newPerms ) = @_;
        $self->{_perms} = $newPerms;
    }
    # return ( $remote, $local )
    sub sortByLocation {
        my ($class, $x, $y ) = @_;
        if ( $x->isRemote() ){
            if ( $y->isRemote() ){
                PrgBug->throw ( "Both objects are remote" );
            }
            return ($x,$y);
        }
        return ($y,$x);
    }
    # return true if object is remote
    sub isRemote {
        return 0;
    }
    # return true if object is remote and new
    sub isNew {
        my ( $self ) = @_;
        if ( exists ($self->{_new} ) ){
            return $self->{_new};            
        }        
        return 0;
    }
    sub set {
        my ( $self, $other ) = @_;
        if ( $other->isRemote() ){
            $other->set ( $self );
        }else{
            PrbBug->throw ( "Both objects are local" );
        }        
    }    
}
{
    package FileLeaf;
    use base qw ( FileObject );
    sub new {
        my ($class, $path, $perms, $moddate, $size) = @_;
        my $self = $class->SUPER::new( $path, $perms );
        $self->setModDate ( $moddate );
        $self->setSize ( $size );
        return $self;
    }
    # return date of last modification in the epoch format ( integer )
    sub getModDate {
        my ( $self ) = @_;
        return $self->{_moddate};
    }
    sub setModDate {
        my ( $self, $newmoddate ) = @_;
        return $self->{_moddate} = $newmoddate ;
    }    
    # return size of the file
    sub getSize {
        my ( $self ) = @_;
        return $self->{_size};
    }
    sub setSize {
        my ( $self, $newsize ) = @_;        
        return $self->{_size} = $newsize ;
    }
    # return true if objects are coincidence
    sub equal {
        # one of these is remote
        my ( $remotef,  $localf ) = FileObject->sortByLocation( @_ );
        return !(  $remotef->isNew() or
                   $remotef->getModDate() < $localf->getModDate() or
                   $remotef->getSize() != $localf->getSize() or
                   $remotef->getPerms() != $localf->getPerms()
            );
    }
}

{
    package MixLocal;
    sub load {
        my ( $class, $path ) = @_;
        my @stat = lstat $path;
        if ( ! @stat ){
            FileNotFound->throw( $path );
        }        
        my $self = $class->instantiateObject( $path, \@stat );
        return $self;
    }    
}

{
    package LocalFile;
    use base  qw ( FileLeaf MixLocal);
    sub instantiateObject {
        my ( $class, $path, $stat ) = @_;
        return $class->new( $path, 01777 & $stat->[2], $stat->[9], $stat->[7] );            
    }
}

{
    package MixRemote;
    sub isRemote { return 1; }
    # delete a file or a dir from remote host and local db
    sub delete {
        my ( $self ) = @_;
        my $path = $self->getPath();
        my $ftp = $self->{ftp};
        if ( ! $self->deleteRemoteObjAndCheck( $path, $ftp ) ){
            NetWorkEx->throw( "Cannot to remote file '"
                              . $self->getPath() . "'"  );
        }
        $self->{dbh}->deleteFile ( $path );
    }
    
    # remote file doesn't exist yet.
    sub newFileObject {
        my ( $class, $ftp, $dbh, $path ) = @_ ;
        my $self =  $class->load ( $ftp,
                                   $dbh,
                                   { size => 0, perms => 0,
                                     date => 0, fullname => $path }
            );
        $self->{_new} = 1;
        return $self;
    }
    # load from db
    sub load { 
        my ( $class, $ftp, $dbh, $info ) = @_ ;
        my $self = $class->instantiateObject ( $info->{fullname}, $info );       
        $self->{ftp} = $ftp;
        $self->{dbh} = $dbh;
        $self->{_new} = 0;
        return $self;        
    }    
}

{
    package RemoteFile;
    use base qw( FileLeaf MixRemote );

    sub deleteRemoteObjAndCheck {
        my ( $self, $path, $ftp ) = @_;
        return $ftp->delete ( $path ) or ! $ftp->size( $path );
    }
    #load info about remote file from db
    # remote file already exists
    sub instantiateObject {
        my ( $class, $path, $info ) = @_ ;
        return $class->new ( $path,
                             $info->{perms},
                             $info->{date},
                             $info->{size} );       
    }

    sub writeToDb {
        my ( $self, $localf ) = @_;
        if ( $self->isNew ){
            $self->{_new}=0;
            $self->setPath ( $localf->getPath );
            #insert db
            $self->{dbh}->uploadFile ( $self->getPath,
                                       $self->getPerms,
                                       $self->getModDate,
                                       $self->getSize );
        }else {
            # update db
            $self->{dbh}->reuploadFile ( $self->getPath,
                                         $self->getPerms,
                                         $self->getModDate,
                                         $self->getSize );            
        }                
    }
    sub set {
        my ( $self, $localf ) = @_;
        if ( $self->isNew
             or $self->getSize != $localf->getSize
             or $self->getModDate < $localf->getModDate ) {
            my $p = $localf->getPath;
            my $res = $self->{ftp}->put( $p, $p );
            if ( !defined( $res ) or ($res ne $p) ){
                NetWorkEx->throw ( "Could not put '" . $localf->getPath . "' file" );
            }
            $self->setSize ( $localf->getSize );
            $self->setModDate ( $localf->getModDate()  );            
        }
        
        if ( $self->getPerms != $localf->getPerms ){
            $self->{ftp}->setPerms ( $localf->getPath, $localf->getPerms );
            $self->setPerms ( $localf->getPerms );            
        }
        $self->writeToDb ( $localf );
    }
}

{
    package FileNode;
    use base qw ( FileObject );
    # parent of folder classes
    sub equal {
        # one of these is remote
        my ( $remotef, $localf ) = FileObject->sortByLocation( @_ );
        return ! ( $remotef->isNew()
            or $remotef->getPerms() != $localf->getPerms() );
    }    
}

{
    package RemoteDir;
    use base qw ( FileNode MixRemote );
    # return true if object doesn't already exist
    sub deleteRemoteObjAndCheck {
        my ( $self, $path, $ftp ) = @_;
        my $res = $ftp->rmdir ( $path );       
        return  defined( $res ) and ( $res eq 1 )
            or ( ! $ftp->ls ( $path ) );
    }

    sub instantiateObject {
        my ( $class, $path, $info ) = @_;
        return $class->new ( $path, $info->{perms} );        
    }
    sub set {
        my ( $self, $locald ) = @_;
        if ( $self->isNew ){
            my $x = $locald->getPath;
            my $res = $self->{ftp}->mkdir( $x );
            if ( !defined($res) and !$self->{ftp}->ls($x) ){
                NetWorkEx->throw ( "Cannot create '" . $locald->getPath() . "' directory" );
            }
        }
        $self->{ftp}->setPerms ( $locald->getPath, $locald->getPerms );
        if ( $self->isNew ){
            $self->{dbh}->createDir ( $locald->getPath, $locald->getPerms );
        }else {
            $self->{dbh}->setPerms ( $locald->getPath, $locald->getPerms );
        }                        
    }
}

{
    package LocalDir;
    use base qw ( FileNode MixLocal);
    sub instantiateObject {
        my ( $class, $path, $stat ) = @_;
        return $class->new( $path, 01777 & $stat->[2] );            
    }
}

{
    package FactoryOfRemoteObjects;    
    sub new {
        my ( $class, $ftp, $dbh ) = @_;
        my $self = { ftp => $ftp, dbh => $dbh };
        bless $self, $class;
        return $self;
    }
    # return object RemoteFile
    sub createFile {
        my ( $self, $path ) = @_;
        return RemoteFile->newFileObject ( $self->{ftp}, $self->{dbh}, $path );
    }
    # retur object RemoteDir
    sub createDir {
        my ( $self, $path ) = @_;
        return RemoteDir->newFileObject ( $self->{ftp}, $self->{dbh}, $path );        
    }
}

{
    package TurboPutCommand;
    sub new {
        my ( $class, $factory, $localFiles, $localDirs, $remoteFiles,  $remoteDirs ) = @_;
        my $self = {
            lfiles => $localFiles, rfiles => $remoteFiles,
            rdirs => $remoteDirs, ldirs => $localDirs,
            encounteredErrors => 0,
            remoteObjectFactory => $factory,
            # list of folder names which cannot be created on a remote host
            ignorePrefix => []
        };
        bless $self, $class;
        return $self;
    }
    sub getRemoteFile {
        my ( $self, $path ) = @_;
        if( exists $self->{rfiles}->{$path} ) {
            return $self->{rfiles}->{$path};
        }
        return $self->{remoteObjectFactory}->createFile( $path );
    }
    sub getRemoteDir {
        my ( $self, $path ) = @_;
        if ( exists $self->{rdirs}->{$path} ){
            return $self->{rdirs}->{$path};
        }
        my $d = $self->{remoteObjectFactory}->createDir( $path );
        return $d;
    }
    sub errorHappend {
        my ( $self ) = @_;
        if ( $theOpts->{maxerrors} == 0 ) { return; }
        $self->{encounteredErrors} += 1;
        if ( $self->{encounteredErrors} >= $theOpts->{maxerrors} ){
            print STDERR "There was " . $self->{encounteredErrors} . " errors\n";
            print STDERR "Process was self terminated\n";
            exit 1;
        }
    }
    sub syncFiles {
        my ( $self ) = @_;
        my $lfiles = $self->{lfiles};
        foreach my $curlocalfile ( sort { return length($b) <=> length($a); }
                                   keys(%$lfiles) )
        {
            my $lfile = $lfiles->{$curlocalfile};
            my $rfile = $self->getRemoteFile ( $lfile->getPath() );
            if ( ! $lfile->equal( $rfile ) ){
                eval {
                    $rfile->set( $lfile );
                    if ( !$theOpts->{doquiet} ) { print "File '$curlocalfile' was uploaded.\n";  }
                };
                if ( my $ex = Exception::Class::Base->caught() ) {
                    print STDERR "$ex->{message}\n";
                    $self->errorHappend();
                }
            }
        }
    }
    sub syncDirectories {
        my ( $self ) = @_;
        my $curlocaldir;
        my $toBeIgnored = $self->{ignorePrefix};
        my $ldirs = $self->{ldirs};
      UploadFileObject:
        foreach $curlocaldir ( sort { return length($a) <=> length($b); }
                               keys( %$ldirs ) )
        {
            foreach my $badFolder ( @$toBeIgnored ){
                if ( $badFolder eq substr( $curlocaldir, length( $badFolder ) ) ){
                    next UploadFileObject;
                }
            }
            my $ldir = $ldirs->{$curlocaldir};
            my $rdir = $self->getRemoteDir ( $ldir->getPath() );
            if ( ! $ldir->equal( $rdir ) ){
                eval {
                    $rdir->set($ldir );
                    if ( !$theOpts->{doquiet} ) { print "Folder '$curlocaldir' was uploaded.\n";  }
                };
                if ( my $ex = Exception::Class::Base->caught() ) {
                    $toBeIgnored->[ ++$#$toBeIgnored ] = $curlocaldir;
                    $self->errorHappend();
                }
            }
        }
    }
    sub deleteRemoteFiles {
        my ( $self ) = @_;
        my $rfiles = $self->{rfiles};
        my $lfiles = $self->{lfiles};
        my $ftp = $self->{ftp};
        my $dbh = $self->{dbh};
        foreach my $rfilename ( keys  %$rfiles  ) {
            if ( ! exists $lfiles->{$rfilename} ){
                eval {
                    $rfiles->{$rfilename}->delete();
                    if ( !$theOpts->{doquiet} ) {
                        print "Delete file '$rfilename'.\n";
                    }
                };
                if ( my $ex = Exception::Class::Base->caught() ){
                    print STDERR "Could not remove remote file '$rfilename'\n";
                    $self->errorHappend();                    
                }
            }
        }                
    }
    sub deleteRemoteDirectories {
        my ( $self ) = @_;
        my $rdirs = $self->{rdirs};
        my $ldirs = $self->{ldirs};
        my $ftp = $self->{ftp};
        my $dbh = $self->{dbh};
        foreach my $rdirname ( sort  { return length($b) <=> length($a); }
                               keys  %$rdirs  ) {

            if ( ! exists $ldirs->{$rdirname} ){
                eval {
                    $rdirs->{$rdirname}->delete();
                    if ( !$theOpts->{doquiet} ) { print "Delete folder '$rdirname'.\n";  }                    
                };
                if ( Exception::Class::Base->caught() ){
                    print STDERR "Could not remove remote subdirectory '$rdirname'\n";
                    $self->errorHappend();                    
                }
            }
        }        
    }
    sub dosync {
        my ( $self ) = @_;
        if ( !$theOpts->{doquiet} ) { print "Sync folders.\n";  }        
        $self->syncDirectories();
        if ( !$theOpts->{doquiet} ) { print "Sync files.\n";  }                
        $self->syncFiles();
        if (! $theOpts->{nodelete} )
        {
            if ( !$theOpts->{doquiet} ) { print "Delete unexisted files.\n";  }                    
            $self->deleteRemoteFiles();
            if ( !$theOpts->{doquiet} ) { print "Delete unexisted folders.\n";  }                                
            $self->deleteRemoteDirectories();
        }        
    }
}

package main;

STDOUT->autoflush(1);
STDERR->autoflush(1);

$theOpts =  PrgOpts->new ( \@ARGV );

my $dbh = DBI->connect("dbi:SQLite:dbname=$theOpts->{dbpath}", "", "")
    or die "Cannot create or open db '$theOpts->{dbpath}'";
$dbh = new UploadedFiles( $dbh );

if ( $theOpts->{newDB} ) {
    $dbh->deployScheme();
}

my $ftpc = undef;
if ( ! $theOpts->{buildDB} ){
    $ftpc = MyFtp->connection();
}

if ( !$theOpts->{doquiet} ) {
    print "\nBuilding local file tree.\n";
}

my ( $ldirs, $lfiles ) = main->buildlocaltree();

if ( $theOpts->{buildDB} ){
    main->fillDb ( $dbh, $ldirs, $lfiles);    
    exit;
}

if (! $theOpts->{doquiet} ) {
    print "\nBuilding remote file tree.\n";
}

my ( $rdirs, $rfiles ) = main->buildremotetree( $ftpc, $dbh );

if ( !$ftpc->isConnected ) {
    if (! $theOpts->{doquiet} ) { print "\nReconnect to server.\n"; }    
    $ftpc = MyFtp->connection();
    foreach my $rdir ( values ( %$rdirs ) ){
        $rdir->{ftp} = $ftpc;
    }
    foreach my $rfile ( values ( %$rfiles ) ){
        $rfile->{ftp} = $ftpc;
    }    
} 

if ( !$theOpts->{doquiet} ) {
    print "\nStarting synchronization.\n";
}

my $factory = FactoryOfRemoteObjects->new ( $ftpc, $dbh );

my $cmd = TurboPutCommand->new ( $factory, $lfiles, $ldirs, $rfiles,  $rdirs );
$cmd->dosync();
if ( !$theOpts->{doquiet} ) { print "Done.\n"; }
if ( $theOpts->{dodebug} )  { print "Quitting FTP connection.\n" }
$ftpc->quit();
exit 0;

sub buildlocaltree () {
    my ( $class ) = @_;
    my %ldirs = ();
    my %lfiles = ();
    chdir $theOpts->{localdir};    
    my $ldl = length ( Cwd::getcwd() );
    if ($theOpts->{doflat}) {
        my @globbed=glob("{*,.*}");
        foreach my $curglobbed (@globbed) {
            next if (! -f $curglobbed);
            $lfiles{$curglobbed} = LocalFile->load ( $curglobbed );            
        }
    } else {
        find ( { wanted=> sub { noticelocalfile ( $File::Find::name,
                                                  \%ldirs,
                                                  \%lfiles, $ldl ) ;  },
                 follow_fast => $theOpts->{followsymlinks},
                 no_chdir => 1
               },
               
               Cwd::getcwd()."/"
            );
    }
    return ( \%ldirs, \%lfiles );
    
    sub noticelocalfile {
        my ( $fileName, $ldirs, $lfiles, $ldl ) = @_;
        my $relfilename = substr( $fileName, $ldl );
        $relfilename =~ s!^/!!;
        if (length($relfilename) == 0) { return; }        
        if ($theOpts->{ignoremask} ne "") {
            if ($relfilename =~ /$theOpts->{ignoremask}/ ) {
                if ($theOpts->{doverbose}) {
                    print "Ignoring $relfilename which matches $theOpts->{ignoremask}\n";
                }
                return;
            }
        }
        if (-d $_) {
            $ldirs->{$relfilename} = LocalDir->load ( $relfilename );
        }elsif (-f $_) {
            $lfiles->{$relfilename} = LocalFile->load ( $relfilename );
        }elsif (-l $_) {
            print "Link isn't supported: $fileName\n";
        }elsif (! $theOpts->{doquiet}) {
            print "Ignoring file of unknown type: $fileName\n";
        }
    }
}

# restore information from db file into vars: %remotelinks,
#          %remotedirs, %remotefilesize and %remotefiledates.
sub buildremotetree() {
    my ( $class, $ftp, $dbh  )  = @_;
    my %rdirs = ();
    my %rfiles = ();
    my $dirs = $dbh->selectAllDirs();
    foreach my $dir ( @$dirs ){
        $rdirs{ $dir->{fullname} } = RemoteDir->load ( $ftp, $dbh, $dir ) ;
    }
    my $files = $dbh->selectAllFiles();
    foreach my $file ( @$files ){
        $rfiles{ $file->{fullname} } = RemoteFile->load( $ftp, $dbh, $file );
    }
    return ( \%rdirs, \%rfiles );
}

sub fillDb {
    my ( $class, $dbh, $ldirs, $lfiles ) = @_;
    foreach my $lfile ( values ( %$lfiles ) ) {
        $dbh->uploadFile( $lfile->getPath,
                          $lfile->getPerms,
                          $lfile->getModDate,
                          $lfile->getSize );
    }
    foreach my $ldir ( values ( %$ldirs ) ) {
        $dbh->createDir( $ldir->getPath, $ldir->getPerms );
    }
}

=pod

=head1 NAME

turbo-ftp-sync - a script moves changes of files and folders of a local
machine to a remote one via FTP very fast with minimum network traffic.

=head1 SYNOPSIS

turbo-ftp-sync [ options ] [ <localdir> <remoteURL> ]

=head1 DESCRIPTION

The script synchronizes files and folder on an FTP server with local ones via
usual FTP protocol. The advantage of this script over usual FTP client is it
doesn't upload all data every time but only once. 

Its secret is that it doesn't ask a FTP server about last modification date and
current size of each file. These information is stored in local SQLite db.
Therefore this program doesn't explore folder tree of a remote host. It acts
blindly. You can interrupt a process of this program in any time and you will
not lose changes which you already uploaded.

The program can move changes only one direction from a local machine to remote
one. If a file was changed on a remote machine and a local one then the program
overwrite the remove version of the file by the local one.

turbo-ftp-sync.pl is based on sources of ftpsync.pl program.
Christoph Lechleitner is the initial author of ftpsync.pl (ftpsync@ibcl.at)

=head1 OPTIONS

=over 

=item <localdir>

local directory, by default is current one(.)

=item <remoteUrl>

full FTP URL 

  ftp://[ftpuser[:ftppasswd]@]ftpserver/ftpdir 

ftpdir is relative, so

  ftp://[ftpuser[:ftppasswd]@]ftpserver// for absolute paths

=item -c | -C 

like -i, but then prompts whether to actually do work

=item -d | -D  

turns debug output (including verbose output) on

=item -f | -F

flat operation, no subdir recursion

=item -h | -H

prints out this help text

=item -i | -I

forces info mode, only telling what would be done

=item -n | -N

no deletion of obsolete files or directories

=item -l | -L

follow local symbolic links as if they were directories

=item -q | -Q

turns quiet operation on

=item -b | -B

build DB only - i.e don't upload data to remote host.  For example you have
alread upload an archive to a remote host and extracted it. Then the remove copy
of data equals to local one. And reuploading all data yet another time with this
script is redundant.

  # Instead.
  turbo-ftp-sync.pl db=db.db wroot ftp://ftp.com//

  # Use
  turbo-ftp-sync.pl -b db=db.db wroot 
  # here you change something in wroot folder
  turbo-ftp-sync.pl db=db.db wroot ftp://ftp.com//

=item -v | -V

turnes verbose output on

=item maxerrors

if not 0 then program exit with nonzero code.

=item cfg

read parameters and options from file defined by value.

=item ftpserver

defines the FTP server, defaults to "localhost".

=item ftpuser

defines the FTP user, defaults to "ftp".

=item db

defines the file where info about uploaded files is stored.

=item ftppasswd

defines the FTP password, defaults to "anonymous".

=item ignoremask

defines a regexp to ignore certain files, like .svn

=back 

=head1 EXAMPLE of using maxerrors feature

It allow to self terminate process if it was encountered definite number failure
attempts to upload a file or a dir. Usually such situation means your free ftp
server bans you.  And it bases on experiency the better decision is to termitate
program with error.  But it's the end. We don't surrender! We've foreseen that.

  while : ; do 
    turbo-ftp-sync.pl db=db.db wroot ftp://ftp.com// && break ; 
  done

=head1 VERSION

0.5

=head1 AUTHOR

Daneel S. Yaitskov <rtfm.rtfm.rtfm@gmail.com>

=head1 COPYRIGHT

Copyright (c) 2011, Daneel S. Yaitskov <rtfm.rtfm.rtfm@gmail.com>

All rights reserved.

This program is free software; you can redistribute it and/or
modify it under the same terms as Perl itself.

=head1 SCRIPT CATEGORIES

Networking
Web    

=cut
