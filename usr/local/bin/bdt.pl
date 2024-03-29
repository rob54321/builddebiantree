#!/usr/bin/perl
use strict;
use warnings;

# this programme exports all debian source packages from svn and git
# builds the debian packages, places then in the debian tree, builds the
# Packages file, updates apt-get.
use File::Path;
use File::Basename;
use File::Find;
use Getopt::Std;
use Cwd;
use File::Glob;

# global variables
my ($svn, $config_changed, $version, $configFile, $dist, @all_arch, $workingdir, $gitremotepath, $debianroot, $pubkeyfile, $secretkeyfile, $sourcefile, $debhomepub, $debhomesec);
our ($opt_n, $opt_B, $opt_c, $opt_h, $opt_w, $opt_f, $opt_b, $opt_S, $opt_t, $opt_p, $opt_r, $opt_x, $opt_G, $opt_F, $opt_V, $opt_g, $opt_s, $opt_d, $opt_l, $opt_R, $opt_k, $opt_K);

# sub to get a source tarball and include it in the debian package for building
# if it is required
# the source file is kept in debianroot/source
# The postinst is checked to see if it has SOURCE=source_file, tar or bz2 or tar.gz or tar.bz2
# this is done so the tarball does not have to be included in subversion
# package name is passed as a parameter. The full directory is
# $workingdir/$packagename
# returns 1 if tarball sucessfully included in package
# returns 2 if no source required, there may or may not be a postinst
# returns 5 if SOURCE is defined but file not found
sub getsource {
	my $package = shift;
	my $postinst = "$workingdir/$package/DEBIAN/postinst";

	# if a source file is to be loaded then postinst will have:
	#SOURCE=sourefile-version.tar.gz | sourcefile-version.tar.bz2 etc
	# return 2 if there is no SOURCE=
	if (open POSTINST, "<", $postinst) {
		#postinst exists, check for SOURCE to find sourcefile name
		while (my $line = <POSTINST>) {
			chomp($line);
			if ($line =~ /^SOURCE=/) {
				# SOURCE found
				$line =~ s/^SOURCE=//;
				# remove ' and/or ". $line now contains filename-version.tar.bz2 or gz or tar
				$line =~ s/"|\'//g;
				$sourcefile = $line;
			}
		} # end while
		close POSTINST;
	} else {
		# there is no postinst and hence no source
		return 2;
	} # end if open
		
	# if version found set the sourcefile name
	if ($sourcefile) {
		# set sourcefile to full path name
		$sourcefile = $debianroot . "/source/" . $sourcefile;
		# check if source file exists, return error otherwise
		return 5 unless -e $sourcefile;
				
		# copy to the source file to $workingdir/$package/tmp
		mkpath "$workingdir/$package/tmp";
		my $copycmd = "cp -f $sourcefile $workingdir/$package/tmp/";
		system($copycmd);
		return 1;	
	} else {
		# there is a postinst but no source required
		return 2;
	} # end if file_version and sourcefile
}

# sub to get the maximum release number for a package from subversion
# the call getrelease( package_name )
# returns the latest version no, or undef if not found
sub getmaxrelease {
	my $package = shift;

	# get all release numbers.
	my @list = `svn list file://$svn/debian/$package/release/ 2>/tmp/svnerror.log`;

	# check for error
	my $errorlog = `cat /tmp/svnerror.log`;
	if (grep /not found/i, $errorlog) {
		return undef;
	}
	# remove new line as well as trailing slash
	# the versions are returned as 1.3/ etc
	chomp(@list);
	chop (@list);

	my $max = "0";
	# find the maximum version
	# as string comparison must be done
	# as version are of the form 2:2.5.1-2.6.4
	foreach my $ver (@list) {
		$max = $ver if $max lt $ver;
	}
	return $max;
}

# this sub operates on the list @ARGV
# all the switches in the defparam hash are checked to see if they have arguments.
# if they do not have arguments, the default arguments are inserted into ARGV after the switch
# so that getopts will not fail.
# no parameters are passed and none are returned.

sub defaultparameter {

	# the pubkey secretkey files have defaults:
	#    debianroot/pubkey and debianroot/secretkey
	# the debian root may have changed in the comman line switches with the -x option
	# command line: bdt.pl -x newdir ...
	# then the defaults for pubkey and secretkey must change as well
	# find -x directory in @ARGV if it exists
	# the following parameter will be debianroot
	# if the last command line parameter is -x , it has no effect
	# that's why $i < $#ARGV
	for (my $i = 0; $i < $#ARGV; $i++) {
		if ($ARGV[$i] eq "-x") {
			# reset the pubkey and secret key locations
			$debianroot = $ARGV[$i+1];
			# check and remove final / from debianroot
			$debianroot =~ s/\/$//;
			$pubkeyfile = $debianroot . "/" . $debhomepub;
			$secretkeyfile = $debianroot . "/" . $debhomesec;
			last;
		}
	}

	# hash supplying default arguments to switches
	my %defparam = ( -b => $pubkeyfile . " " . $secretkeyfile,
			  -k => $pubkeyfile,
			  -K => $secretkeyfile);

	# for each switch in the defparam hash find it's index and insert default arguments if necessary
	foreach my $switch (keys(%defparam)) {
		# find index of position of -*
		my $i = 0;
		foreach my $param (@ARGV) {
			# check for a -b, -K or -k and that it is not the last parameter
			if ($param eq $switch) {
				if ($i < $#ARGV) {
					# -* has been found at $ARGV[$i] and it is not the last parameter
					# if the next parameter is a switch -something
					# then -* has no arguments
					# check if next parameter is a switch
					if ($ARGV[$i+1] =~ /^-/) {
						# -* is followed by a switch and is not the last switch
						# insert the 2 default filenames as a string at index $i+1
						splice @ARGV, $i+1, 0, $defparam{$switch};
					}
				} else {
					# -* is the last index then the default parameters for -b must be appended
					splice @ARGV, $i+1, 0, $defparam{$switch}; 
				}
			}
			# increment index counter
			$i++;
		}
	}
} 

# sub to write config file of parameters that have changed.
# the hash %config contains the key value pairs of the changed variables
# all three vars workingdir, subversion and debianroot are written
# some may not have changed, then the default values are written
# format is variable value
sub writeconfig {
    # set up hash to save
    my %config = ();
    $config{"workingdir"} = $workingdir;
    $config{"subversion"} = $svn;
    $config{"debianroot"} = $debianroot;
    $config{"gitrepopath"}    = $gitremotepath;
        
    open OUTFILE, ">$configFile";
    foreach my $item (keys (%config)) {
        print OUTFILE "$item $config{$item}\n";
    }
    close OUTFILE;
}

# sub to get config file if it exists
# if the config file exists, defaults will be read from the file
# if there is no config file the original defaults will be used.
sub getconfig {
	# check if file exists
    	if (open INFILE,"<$configFile") {
			        
		# file format:
		# var_name=value
		# read file into hash and set values
		while (<INFILE>) {
			$workingdir = (split " ", $_)[1] if /workingdir/;
			$svn = (split " ", $_)[1] if /subversion/;
			$debianroot = (split " ", $_)[1] if /debianroot/;
			$gitremotepath = (split " ", $_)[1] if /gitrepopath/;
			}
        # set debi	
		# print a message if any defaults were loaded
		print "loaded config file\n";
		close INFILE;
	}
}
	
# sub to make Packages.gz and Packages.bz2 from the packages file
# architecture must be passed as a parameter
sub makeCompressedPackages {
	my($arch) = $_[0];
	
	# make Packages.gzip Packages.bz2
	my($packagesdir) = $debianroot . "/dists/" . $dist . "/main/binary-" . $arch;
	
	# save current dir
	my($currentdir) = cwd;
	chdir $packagesdir;
	system("gzip -f -k Packages");
	system("bzip2 -f -k Packages");

	# set back to previous dir
	chdir $currentdir;
}

# remove working dir
sub removeworkingdir {
	rmtree $workingdir;
}

# given an archive name this function returns the control field
sub getpackagefield {
	my ($archive, $field) = @_;

	# get the package name from the control file
	my @command = ("dpkg-deb -f ", $archive, $field);
	$field = `@command`;
	chomp $field;

	# check if an error was returned from dpkg-deb
	# the error would be dpkg-deb: error: some description
	if ($field =~ /dpkg-deb: error:/) {
		# file is not a debian package
		print "$field\n";
		return undef;
	} else {
		# return control field from package
		return $field;
	}
}

# first parameter packagename.deb
# second parameter is status = debpackage | subversion | git
# debpackage means the archive is a debpackage, rename it to standard form and copy to archive
# subversion means the archive was exported from subversion, built, renamed to standard form and moved to archive
# all destination directories are created
# destination = debianpool / section / firstchar of archive / packagename
# any architecture is moved.
sub movearchivetotree {
	my($debarchive, $status) = @_;

	# keep current directory
	my $currentdir = cwd;
	
	# get section, name, version and architecture to create package directory
	my $section = getpackagefield($debarchive, "Section");
	return unless $section;
	my $packagename = getpackagefield($debarchive, "Package");
	return unless $packagename;
	my $version = getpackagefield($debarchive, "Version");
	return unless $version;
	my $architecture = getpackagefield($debarchive, "Architecture");
	return unless $architecture;

	# make dir under pool/firstletter of packagename/packagename
	# get first character of string
	my $firstchar = substr($packagename, 0, 1);

	# make directory
	my $destination = $debianroot . "/pool/" . $section . "/" . $firstchar . "/" . $packagename;
	mkpath($destination);

	# compare the version of the file being inserted to the existing versions
	# in the destination directory for the same architecture.
	# Do not insert an older version, delete and older version in the repository
	# get version of package in the archive
	chdir $destination;
	# make a list of all files with same package name and architecture
	my @repository_files = glob("$packagename*$architecture.deb");

	# There may be multiple files with different versions in the repository
	# if there are two or more files then check that the file being inserted
	# has a version greater than the maximum version
	# set maximum version
	my $max_version = 0;

	# find the maximum version
	foreach my $file_in_repository (@repository_files) {
		# compare versions
		my $version_in_repository = getpackagefield($file_in_repository, "Version");
		$max_version = $version_in_repository if $max_version lt $version_in_repository;
	}
	
	# Insert file to repository if the new version > than the version in the repository
	chdir $currentdir;
	# check if version > max version unless force option is given
	# create a standard archive name for the deb file
	# packagename_version_architecture
	my $debstdarchive = $packagename . "_". $version . "_" . $architecture . ".deb";

	if ($opt_F or ($version gt $max_version)) {
		# delete all previous versions of files in the repository with the same packagename,
		# architecture in the destination
		system("rm -f " . $destination . "/" . $packagename . "*" . $architecture . ".deb");

		# the deb file from subversion or git
		# will be named packagename.deb
		# it must be renamed to packagename_version_architecture.deb
		# an existing deb file must be renamed to standard form
		# ie packagename_version_architecture.deb
		rename $debarchive, $debstdarchive;
		
		#display message for move debpackage or build and move
		if ($status eq "debpackage") {

			# original was a deb archive, cp it
			print "debpackage: ", $debarchive, " -> $destination/$debstdarchive\n";
			system ("cp " . $debstdarchive . " " . $destination);
		} else {
			# original file was extracted from subversion
			# buildpackage() would have renamed the file with a standard name
			print "$status:  ", $debarchive, " -> $destination/$debstdarchive\n";
			system ("mv " . $debstdarchive . " " . $destination);
		}
		# chmod of file in archive to 0666
		my $pname = $destination . "/" . $debstdarchive;
		chmod (0666, $pname);
	} else {
		# version of new file < existing file
		# file is not inserted
		print "$debarchive = $debstdarchive not inserted $version <= $max_version\n";
	}
}

# add_archive will recursively copy all .deb files to the debian repository
# the package will be renamed to standard form by movetoarchivetree
sub add_archive {
	# get current selection if it is a file
	my $filename = $_;
        
	# for each .deb file, not directory, process it but not in linux-source
	if( -f $filename) {
		# move archive to debian dist tree and create dirs
		if ($filename =~ /\.deb$/) {
			movearchivetotree($filename, "debpackage");
		}
	}
}

# called with buildpackage(workingdirectory, package list)
# this function builds a source package(s) exported from subversion
# into a debian package. The package is then moved to the archive using movetoarchivetree
# movetoarchivetree is called with debian package name and status subversion 
sub buildpackage {
	# get parameters
	my($workdir, $package, $packagervs) = @_;
	# keep current directory
	my $currentdir = cwd;
	
	# change to working directory
	chdir $workdir;

	# build the package and move it to the debian archive
	# check if a package requires a source tarball
	# getsource returns:
	# returns 1 if tarball sucessfully included in package
	# returns 2 if no source required, there may or may not be a postinst
	# returns 5 if source name and version defined but no source file found

	my $gsrc = getsource($package);
	if ($gsrc == 1) {
		print "$package: $sourcefile included\n"

	} elsif ($gsrc == 5) {
		# source and version defined but file not found
		print "$package: $sourcefile defined but not found: skipping\n";
		return;
	}
	# build the package to packagename.deb
	# use deb package name to get full name
	my $rc = system("dpkg-deb -b -Z gzip " . $package . " >/dev/null");
	# check if build was successful
	if ($rc == 0) {
		# the output of dpkg-deb -b is package.deb
		my $debpackage = $package . ".deb";
		movearchivetotree($debpackage, $packagervs);
	} else {
		# control file in DEBIAN directory is not valid or does not exist
		print "control file of $package is not valid\n";
	}
	# restore current directory
	chdir $currentdir;
}

# gitclone is invoked from the -d -g and -n options.
# they require different clone options.
# The options are set my the mode
# mode 1 : invoked by -g  git options: single_branch, depth 1, branch = project name
# mode 2 : invoked by -d  git options: single_branch, depth 1, branch = dev
# mode 3 : invoked by -n  git options: no_checkout, all branches download
# gitclone (package_name, mode, targetdirectory)
# the return code from the git clone command is returned.
sub gitclone {
	# get parameters
	my($pname, $mode, $directory) = @_;

	# set options from mode
	my $gitoptions = "";
	if ($mode == 1) {
		$gitoptions = " -v --single-branch --depth=1 -b $pname ";
	} elsif  ($mode == 2) {
		$gitoptions = " -v --single-branch --depth=1 -b dev ";
	} elsif ($mode == 3) {
		$gitoptions = " -v -n ";
	} else {
		# mode is an undefined value, die
		die "mode = $mode is undefined\n";
	}
	
	# project name is project_name.git
	# project_name.git is the repository name
	# remove directory
	rmtree "$directory";
	
	# clone the project	
	my $rc = system("su robert -c 'git clone $gitoptions $gitremotepath$pname.git $directory >>/tmp/git.log 2>&1' ");

	# print an error message if there was an error
	if ($rc != 0) {
		print "Error cloning $pname\n";
	}
	return $rc;
}

# sub to get the remote name
# this sub can only be executed in the git cloned directory
sub getremote {
	my @remotelist = `su robert -c 'git remote'`;
	chomp (@remotelist);
	return $remotelist[0];
}


# sub to determine latest commit of latest branch
# and checkout the latest branch
# sub to get latest branch with latest commit checked out
# lbranch no parameters passed or returned
# this sub can only be executed in the git cloned directory
sub lbranch { 
	# get remote name
	my $rname = getremote;
	
	# get heads and sort
	# line 0 will be the latest head, line 1 next etc
	my @line = `su robert -c 'git ls-remote --heads --sort=-committerdate $rname'`;

	# each line contains "commit refs/heads/branch_name"
	# the first line will have the newest date
	# get branch latest branch, it will appear first on the list
	my $lbranch = (split (/\//, $line[0]))[2];
	chomp($lbranch);

	# checkout latest branch so software is available to place in the linux repo
	my $rc = system("su robert -c 'git checkout $lbranch >>/tmp/git.log 2>&1'");
	die ("Could not checkout $lbranch from $rname:$!\n") unless $rc == 0;
	
	# print remote name and latest branch
	print "remote: $rname\t latest branch: $lbranch\n";
}



sub usage {
    print "usage: builddebiantree [options] filelist\
-b backup public and secret key to : \"pubkeyfile secretkeyfile\" if blank use defaults $pubkeyfile $secretkeyfile\
-k import public key from subversion to /etc/apt/keyrings\
-K import secret key from subversion\
-l list debian packages in subversion\
-p [\"pkg1 pkg2 ...\"] extract package latest release from subversion -> build -> add to distribution tree\
-t [\"pkg1 pkg2 ...\"] extract package from trunk/root in subversion, build->add to archive tree\
-g [\"pkg1 pkg2 ...\"] extract package from git project branch, build->add to tree\
-d [\"pkg1 pkg2 ...\"] extract package from git dev branch, build->add to tree\
-n [\"pkg1 pkg2 ...\"] extract package from git newest branch, build->add to tree\
-r [\"dir1 dir2 ...\"] recurse directory for deb packages list containing full paths, build -> add to archive\
-B [path to debian source tree] builds a debian package and adds to archive\
-F force package to be inserted in tree regardless of version\
-x path, to existing respository, default: $debianroot\
-c path, create a new repository at path
-s scan packages to make Packages\
-S full path of subversion default root: $svn\
-G full path of git repo, default: $gitremotepath
-f full path filename to be added\
-w set working directory: $workingdir\
-V print version and exit\
-R reset back to defaults and exit\n";
}

#####################################################
##### main entry #####
#####################################################

# delete logfile
unlink "/tmp/git.log";

# default values
$configFile = "$ENV{'HOME'}/.bdt.rc";
$dist = "home";
@all_arch = ("amd64", "i386", "armhf", "arm64");

# full path to cloned project is
# $workingdir/$package_name
$workingdir = "/tmp/debian";

$svn = "/mnt/svn";

# the git remote path must be
# appended by /
$gitremotepath = "https://github.com/rob54321/";

$debianroot = "/mnt/debhome";
$sourcefile = undef;
$debhomepub = "debhomepubkey.asc";
$debhomesec = "debhomeseckey.gpg";
# used for the -r option to work with relative paths
# store the current working directory absolute path
my $initialdir = cwd;

# get config file now, so that command line options
# can override them if necessary
getconfig;

# debian root may have changed.
# keyfile are set here.
$pubkeyfile = $debianroot . "/" . $debhomepub;
$secretkeyfile = $debianroot . "/" . $debhomesec;

# if no arguments given show usage
my $no_arg = @ARGV;

# check if -b has an argument list after it.
# if not insert default arguments			

################## testing ##################
# print "before: @ARGV\n";
# the defaultparameter() may change debianroot the pubkeyFile and secretkeyFile values
defaultparameter();
# print "after:  @ARGV\n";

# get command line options
getopts('n:B:c:FVt:kKb:hS:lp:r:x:d:sf:w:Rg:G:');


# if no options or h option print usage

if ($opt_h or ($no_arg == 0)) {
	usage;
	# exit
	exit 0;
}
# if -c and -x are not given then use
# the default repository. Make sure it is accessible
if ( ! $opt_c and ! $opt_x ) {
	# check that the default repository is accessible
	die "Cannot access repository at $debianroot" . "/dists/home/main: $!" unless -d $debianroot . "/dists/home/main";
}

# create a new repository
# conflicts with option -x use an existing repository
if ($opt_c) {
	# check that -x is not given
	die "-c and -x are mutually exclusive. Exiting..\n" if $opt_x;

	# the directories must not exist
	if (-d $opt_c) {
		# error message and exit
		print "$opt_c exists: cannot create a repository here\n";
		exit 0;
	} else {
		# set path to use
		$debianroot = $opt_c;

		# strip any tailing / from path
		$debianroot =~ s/\/$//;

		# check if path has leading /
		$debianroot =~ /^\// or die "The repository path: $debianroot is not absolute\n";

		# create the directories
        # make Packages directories if they don't exist
        foreach my $architem (@all_arch) {
          	my $packagesdir = $debianroot . "/dists/" . $dist . "/main/binary-" . $architem;
           	mkpath($packagesdir) if ! -d $packagesdir;
        }
		mkpath($debianroot . "/pool");

        # debhome.sources must be edited with the new url
        #in debhome.sources: URIs: file:///path/to/repo must be
        # changed to URIs: file:///newpath/to/newrepo
        #for sed a file:///mnt/debhome must be used as file:\/\/\/mnt\/debhome
        # each / must be replaced by \/
        my $newdebroot = "file://" . $debianroot;
        $newdebroot =~ s/\//\\\//g;
        system("sed -i -e 's/^URIs:.*/URIs: $newdebroot/' /etc/apt/sources.list.d/debhome.sources");

        # debian root changed, flag it for writing to config file
    	$config_changed = "true";
	}
}

# set up an existing repository to use
# the directory structure must exist
if ($opt_x) {
	# check that -c is not given
	die "-c and -x are mutually exclusive. Exiting..\n" if $opt_c;

	$debianroot = $opt_x;
	# strip any trailing /
	$debianroot =~ s/\/$//;

    # check if path has leading /
    $debianroot =~ /^\// or die "The repository path: $debianroot is not absolute\n";

	if (! -d $debianroot . "/dists/" . $dist . "/main") {
		# directory structure incomplete
		print $debianroot . "/dists/home/main does not exist\n";
		exit 0;
	}

    # debhome.sources must be edited with the new url
    #in debhome.sources: URIs: file:///path/to/repo must be
    # changed to URIs: file:///newpath/to/newrepo
    #for sed a file:///mnt/debhome must be used as file:\/\/\/mnt\/debhome
    # each / must be replaced by \/
    my $newdebroot = "file://" . $debianroot;
    $newdebroot =~ s/\//\\\//g;
    system("sed -i -e 's/^URIs:.*/URIs: $newdebroot/' /etc/apt/sources.list.d/debhome.sources");
	# set flag to say a change has been made
	$config_changed = "true";
}

# print version and exit
if ($opt_V) {
	# print the installed version from dpkg-query
	my $string = `dpkg-query -W builddebiantree`;
	my ($name, $version) = split /\s+/,$string;
	print "Version: $version (installed version)\n";
	exit 0;
}

# reset by deleting config file and exit
# subversion , debhome repository, working dir, git repo must be reset
if ($opt_R) {
	unlink($configFile);

    #debhome.source must be reset to the default
    # extract debhome.sourses from subversion
    # the file is architecture dependent
    my $arch = `arch`;
    chomp($arch);
    
    if ($arch eq "aarch64") {
        # extract for arm64
        my $rc = system("svn export --force file://" . $svn . "/root/my-linux/sources/arm64/debhome.sources /etc/apt/sources.list.d");
        die("Could not extract debhome.sources from $svn/root/my-linux/sources/arm64\n") unless $rc == 0;
    } elsif ($arch eq "x86_64") {
        # extract for amd64
        my $rc = system("svn export --force file://" . $svn . "/root/my-linux/sources/amd64/debhome.sources /etc/apt/sources.list.d");
        die("Could not extract debhome.sources from $svn/root/my-linux/sources/amd64\n") unless $rc == 0;
    } else {
        # unknown architecture
        die("$arch is and unknown architecture\n");
    }
	print "deleted config file\n";
	exit 0;
}

# set the git repository path if changed
if ($opt_G) {
	$gitremotepath = $opt_G;
	# add a final / to gitrepopath if one does not exist
	$gitremotepath = $gitremotepath . "/" unless $gitremotepath =~ /\/$/;
	
	$config_changed = "true";
}

# set subversion respository root path
if ($opt_S) {
        $svn = $opt_S;
        # strip trailing /
        $svn =~ s/\/$//;

        # set flag to say a change has been made
        $config_changed = "true";
}

# set working directory if changed
if ($opt_w) {
    $workingdir = $opt_w;
        
        # set flag to say a change has been made
        $config_changed = "true";
}

# save config file if it has changed
writeconfig if $config_changed;


# backup up keys
# public key is written in armor format
# secret key is binary
# keys are written to default files if -b has no parameters
# non default parameters order: publickey_name secretkey_name
if ($opt_b) {

	# get full path names for the public and secret keys
	($pubkeyfile, $secretkeyfile) = split /\s+/, $opt_b;
		
	# create their directories if they do not exist
	# print "pubkey is in " . dirname($pubkeyfile) . "\n";
	# print "secret key is in " . dirname($secretkeyfile) . "\n";
	mkpath(dirname($pubkeyfile)) if ! -d dirname($pubkeyfile);
	mkpath(dirname($secretkeyfile)) if ! -d dirname($secretkeyfile);

	# the keyid or name should be used for export. This works because
	# there is only one key. In general all keys are exported
	# when no keyid or name is given. Luckily only one key exists
	# export the public key, generated from the secret key
	my $backuppub = "gpg --output ". $pubkeyfile . " --export --armor";
	system($backuppub) == 0 or die "$backuppub failed: $?\n";
	# chmod to 0644
	chmod (0644, $pubkeyfile);

	my $backupsec = "gpg --output ". $secretkeyfile . " --export-secret-keys --export-options backup";
	system($backupsec) == 0 or die "$backupsec failed: $?\n";
	print "backed up public key to: " . $pubkeyfile . "\n";
	print "backed up secret key to: " . $secretkeyfile . "\n";

}

# import public key
# the key is copied to /etc/apt/keyrings/debhomepubkey.asc
########### this must change ###################
if ($opt_k) {
	# if public key is in file:///mnt/svn/root/my-linux/sources/gpg/debhomepubkey.asc

	# make directory /etc/apt/keyrings if it does not exist
	mkpath "/etc/apt/keyrings";

	# extract the file from subversion
	# check that the subversion respository is available
	if (-d $svn) {
		my $command = "svn export --force file:///mnt/svn/root/my-linux/sources/gpg/" . $debhomepub . " /etc/apt/keyrings";
		my $rc = system($command);
		if ($rc == 0) {
			# set mode to 0644
			chmod(0644, "/etc/apt/keyrings/" . $debhomepub);
		} else {
			# could not extract file from subversion
			print "Could not extract file from subversion\n";
		}
	} else {
	print "subversion repository not found\n";
	}
}    

# import the secret key for signing from subversion
if ($opt_K) {
	# check if subversion respository exists
	if (-d $svn) {
		# extract key from subversion repository
		my $command = "svn export --force file:///mnt/svn/root/my-linux/sources/gpg/" . $debhomesec . " /tmp";
		my $rc = system($command);
		if ($rc == 0) {
			#import the key
			my $command = "gpg --import " . "/tmp/" . $debhomesec;
			$rc = system($command);
			# check if imported
			if ($rc != 0) {
				print "Could not import secret key\n";
			}
		} else {
			# could not extract file from subversion
			print "Could not extract file from subversion\n";
		}
	} else {
		# subversion respository not found
		print "subversion respository not found\n";
	}
}

# list all packages
if ($opt_l) {
    my $command = "svn -v list file://" . $svn . "/debian";
    system($command);
}

# set up subversion export command
my $subversioncmd = "svn --force -q export file://" . $svn . "/debian/";

# export the trunk from subversion, build the package and move to the debian tree
# if there is no trunk directory then export from the project directory
if ($opt_t) {
	# export package from trunk and build it, insert into debian repository
    	removeworkingdir;
	my @package_list = split /\s+/, $opt_t;
	foreach my $package (@package_list) {
		# checkout each package in list $opt_t is a space separated string
		print "\n";
		print "--------------------------------------------------------------------------------\n";
		# check if trunk exists
		my $trunk = "/trunk";
		my $rc = system("svn list file://" . $svn . "/debian/" . $package . "/trunk > /tmp/svn.log 2>&1");
		$trunk = "/" unless $rc == 0;
    		my $command = $subversioncmd . $package . $trunk . " " . $workingdir . "/" . $package . " 1>/tmp/svn.log 2>/tmp/svnerror.log";
	    	if (system($command) == 0) {
			print "exported file://" . $svn . "/debian/" . $package . $trunk . "\n";
			# build the package and move it to the tree
			buildpackage($workingdir, $package, "subversion trunk");
		} else {
			my $error = `cat /tmp/svnerror.log`;
			print "$error\n";
		}
	} # end foreach
}
# export the latest release, build the package and move to the debian tree
# also check if a source tarball is required and insert it into the debian package
if ($opt_p) {
	# empty working dir incase
	removeworkingdir;

	# checkout each package in list $opt_p is a space separated string
	my @package_list = split /\s+/, $opt_p;
	foreach my $package (@package_list) {
		print "\n";
		print "--------------------------------------------------------------------------------\n";
		# get latest release no
		my $release = getmaxrelease($package);
		if ($release) {
		    	my $command = $subversioncmd . $package . "/release/" . $release . " " . $workingdir . "/" . $package . " 1>/tmp/svn.log 2>/tmp/svnerror.log";
	    		if (system($command) == 0) {
				print "exported file://" . $svn . "/debian/" . $package . "/release/" . $release . "\n";
				# build the package and move it to the tree
				buildpackage($workingdir, $package, "subversion release");
			} else {
				my $error = `cat /tmp/svnerror.log`;
				print "$error\n";
			}
		} else {
			print "There is no release for package $package\n";
		} # end if release
	} # end foreach
}

# export a package from git, project branch, build it and insert into the repository
# export to depth 1 and delete .git directory
# this options assumes the branch name is the same as the package name.
if ($opt_g) {
	# checkout each package in list $opt_t is a space separated string
	my @package_list = split /\s+/, $opt_g;

	foreach my $package (@package_list) {
		print "\n";
		print "--------------------------------------------------------------------------------\n";

	    	if (gitclone($package, 1, $workingdir . "/" . $package) == 0) {
	    		# remove .git directory
    			rmtree $workingdir . "/" . $package . "/.git";

    			# remove the readme file and .gitignore
    			unlink "$workingdir" . "/" . "$package" . "/README.md";
    			unlink "$workingdir" . "/" . "$package" . "/.gitignore";

			# build the package and move it to the tree
			buildpackage($workingdir, $package, "git");
		}
	}
}

# export a package from git, development branch, build it and insert into the repository
# export to depth 1 and delete .git directory
if ($opt_d) {
	# checkout each package in list $opt_t is a space separated string
	my @package_list = split /\s+/, $opt_d;

	foreach my $package (@package_list) {
		print "\n";
		print "--------------------------------------------------------------------------------\n";

	    	if (gitclone($package, 2, $workingdir . "/" . $package) == 0) {
	    		# remove .git directory
    			rmtree $workingdir . "/" . $package . "/.git";

    			# remove the readme file and .gitignore
    			unlink "$workingdir" . "/" . "$package" . "/README.md";
    			unlink "$workingdir" . "/" . "$package" . "/.gitignore";
    			
			# build the package and move it to the tree
			buildpackage($workingdir, $package, "git");
		}
	}
}

# export the latest package from git, irrespective of which branch it is on, build it and insert into the repository
# this is the -n newest option
if ($opt_n) {
	# checkout each package in list $opt_t is a space separated string
	my @package_list = split /\s+/, $opt_n;

	foreach my $package (@package_list) {
		print "\n";
		print "--------------------------------------------------------------------------------\n";
		# clone the package
	    	if (gitclone($package, 3, $workingdir . "/" . $package) == 0) {
	    		# checkout the latest branch
	    		chdir $workingdir . "/" . $package;
	    		lbranch;
	    		
	    		# remove .git directory
    			rmtree $workingdir . "/" . $package . "/.git";

    			# remove the readme file and .gitignore
    			unlink "$workingdir" . "/" . "$package" . "/README.md";
    			unlink "$workingdir" . "/" . "$package" . "/.gitignore";
    			
			# build the package and move it to the tree
			buildpackage($workingdir, $package, "git");
		}
	}
}

# process a dir recursively and copy all debian archives to tree
# search each dir for DEBIAN/control. If found build package.
# the opt_r can be a space separated directory list
if ($opt_r) {
	my @directory_list = split /\s+/, $opt_r;
	print "\n";
	print "--------------------------------------------------------------------------------\n";
	foreach my $directory (@directory_list) {
	        # each directory may be an absolute or relative path
	        # absolute paths start with /
	        # relative paths do not start with /
	        # relative paths are relative to the original starting directory
	        # convert all relative paths to absolute paths
	        $directory = $initialdir . "/" . $directory unless $directory =~ /^\//;

	        # check each absolute dir exists
	        print "dir: $directory\n";
    		die "cannot open $directory" if ! -d $directory;

	    	# recurse down dirs and move all
    		find \&add_archive, $directory;
	}
}

# add one specific file to the archive
if ($opt_f) {
	print "\n";
	print "--------------------------------------------------------------------------------\n";
	movearchivetotree($opt_f, "debpackage");			
}
print "\n";
print "--------------------------------------------------------------------------------\n";

# build and add a debian source package to the archive
# the debian source package is not under revision control
# the directory $opt_B will be /home/robert/package
# the debian source tree is under the package directory
# of for relative paths $opt_B may just be the package directory
# in the current directory
if ($opt_B) {
	# empty working directory
	removeworkingdir;

	# strip a trailing /
	$opt_B =~ s/\/$//;;
	
	# make opt_B an absolute directory if it is not
	$opt_B = $initialdir . "/" . $opt_B unless $opt_B =~ /^\//;

	# check that there is a DEBIAN control file
	die ("There is no package source at $opt_B\n") unless -f $opt_B . "/DEBIAN/control";

	# setup package name
	my $package = basename($opt_B);

	# copy the the tree to the working directory
	mkpath($workingdir . "/" . $package) unless -d $workingdir . "/" . $package;
	system("cp -a $opt_B $workingdir/");

	# build the package
	buildpackage($workingdir, $package, "debpackage");

}

# scan pool and make Packages file
if ($opt_s) {

	#change to debian root
	my $currentdir = cwd;
	chdir $debianroot;

	# there is only one distribution ie $debianroot / dists / home 
	# which contains amd64, i386, arm64 and armhf
	# scan all three architectures and write to dists/home/main/binary-arch/Packages
	foreach my $arch (@all_arch) {
		system("apt-ftparchive  --arch " . $arch . " packages pool > dists/" . $dist . "/main/binary-". $arch . "/Packages");

		# make a Packages.gz and Packages.bzip2 in the directory
		makeCompressedPackages($arch);		
		
	}

	# make the release file
	# there is only one release file for all architectures in debianroot/dists/home
	chdir $debianroot . "/dists/" . $dist;
	unlink("Release");
     system("apt-ftparchive -c=/usr/local/bin/apt-ftparchive-home.conf release . > Release");

	# the release file has changed , it must be signed
	system("gpg --clearsign -o InRelease Release");
	system("gpg -abs -o Release.gpg Release");

	# restore original directory
	chdir $currentdir;
}
