#!/usr/bin/perl
use strict;
use warnings;

# this programme exports all debian source packages from svn and
# builds the debian packages, places then in the debian tree, builds the
# Packages file, updates apt-get.
use File::Path;
use File::Basename;
use File::Find;
use Getopt::Std;
use Cwd;
use File::Glob;

# global variables
my ($config_changed, $version, $configFile, $dist, @all_arch, $workingdir, $subversion, $gitrepopath, $debianroot, $debianpool, $pubkeyfile, $secretkeyfile, $sourcefile);
our ($opt_a, $opt_h, $opt_w, $opt_f, $opt_b, $opt_S, $opt_t, $opt_p, $opt_r, $opt_x, $opt_G, $opt_F, $opt_V, $opt_g, $opt_s, $opt_d, $opt_l, $opt_R, $opt_k, $opt_K);

# sub to get a source tarball and include it in the debian package for building
# if it is required
# the source file is kept in debianroot/source
# The postinst is checked to see if it has SOURCE=veracrypt_$VERSION.tar.gz
# this is done so the tarball does not have to be included in subversion
# package name is passed as a parameter. The full directory is
# $workingdir/$packagename
# returns 1 if tarball sucessfully included in package
# returns 2 if no source required, there may or may not be a postinst
# returns 3 if sourcefile name defined in postinst but not the version
# returns 4 if version defined in postinst but not the source name
# returns 5 if source name and version defined but no source file found
sub getsource {
	my $package = shift;
	my $postinst = "$workingdir/$package/DEBIAN/postinst";
	my $file_version = undef;

	# if a source file is to be loaded then postinst will have:
	#VERSION=version_no
	#SOURCE=sourefile-version.tar.gz
	# get the version first, 
	# return 2 if no version or no FILE=
	# return undef if file not found
	if (open POSTINST, "<", $postinst) {
		#postinst exists, check for VERSION and SOURCE
		while (my $line = <POSTINST>) {
			chomp($line);
			if ($line =~ /^VERSION=/) {
				# strip VERSION=
				$line =~ s/^VERSION=//;
				# remove ' and " from $line
				$line =~ s/"|\'//g;
				$file_version = $line;
				# if the source file has been found
				
			} elsif ($line =~ /^SOURCE=/) {
				# SOURCE found
				$line =~ s/^SOURCE=//;
				# remove ' and ". $line now contains name$VERSION.tar.gz
				$line =~ s/"|\'//g;
				$sourcefile = $line;
			}
		} # end while
		close POSTINST;
	} else {
		# there is no postinst and no source
		return 2;
	} # end if open
		
	# if version found set the sourcefile name
	if ($file_version and $sourcefile) {
		# source file = name$VERSION.tar.gz
		# replace $VERSION with the version
		$sourcefile =~ s/\$VERSION/$file_version/;
		$sourcefile = $debianroot . "/source/" . $sourcefile;
		# check if source file exists, return error otherwise
		return 5 unless -e $sourcefile;
				
		# copy to the source file to $workingdir/$package/tmp
		mkdir "$workingdir/$package/tmp" if ! -d "$workingdir/$package/tmp";
		my $copycmd = "cp -f $sourcefile $workingdir/$package/tmp/";
		system($copycmd);
		return 1;	
	} elsif ($sourcefile and (! $file_version)) {
		# only sourcefile name was found but no version in postinst
		return 3;
	} elsif ($file_version and (! $sourcefile)) {
		# only version was found but no source file name in postinst
		return 4;
	} elsif ((! $file_version) and (! $sourcefile)) {
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
	my @list = `svn list file:///mnt/svn/debian/$package/release/ 2>/tmp/svnerror.log`;

	# check for error
	my $errorlog = `cat /tmp/svnerror.log`;
	if (grep /not found/i, $errorlog) {
		return undef;
	}
	# remove new line as well as trailing slash
	# the versions are returned as 1.3/ etc
	chomp(@list);
	chop (@list);

	my $max = 0;
	# find the maximum version
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
			$pubkeyfile = $debianroot . "/publickeyFile.gpg";
			$secretkeyfile = $debianroot . "/secretkeyFile.gpg";
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
    $config{"subversion"} = $subversion;
    $config{"debianroot"} = $debianroot;
    $config{"gitrepopath"}    = $gitrepopath;
        
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
			$subversion = (split " ", $_)[1] if /subversion/;
			$debianroot = (split " ", $_)[1] if /debianroot/;
			$gitrepopath = (split " ", $_)[1] if /gitrepopath/;
			}
	
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
	system("rm -rf " . $workingdir . "/*");
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

# movearchivetotree:
# first parameter is full path to the archive
# second parameter is status = debpackage | subversion | git
# debpackage means the archive is a debpackage, rename it to standard form and copy to archive
# subversion means the archive was exported from subversion, built, renamed to standard form and moved to archive
# all destination directories are created
# destination = debianpool / section / firstchar of archive / packagename
# any architecture is moved.
sub movearchivetotree {
	my($origarchive, $status) = @_;

	# get section, name, version and architecture to create package directory
	my $section = getpackagefield($origarchive, "Section");
	return unless $section;
	my $packagename = getpackagefield($origarchive, "Package");
	return unless $packagename;
	my $version = getpackagefield($origarchive, "Version");
	return unless $version;
	my $architecture = getpackagefield($origarchive, "Architecture");
	return unless $architecture;

	# make dir under pool/firstletter of packagename/packagename
	# get first character of string
	my $firstchar = substr($packagename, 0, 1);

	# make directory
	my $destination = $debianpool . "/" . $section . "/" . $firstchar . "/" . $packagename;
	mkpath($destination) if ! -d $destination;

	# compare the version of the file being inserted to the existing versions
	# in the destination directory for the same architecture.
	# Do not insert an older version, delete and older version in the repository
	# get version of package in the archive
	my $currentdir = cwd;
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

	# archive name has changed to standard name
	my $archive = $packagename . "_". $version . "_" . $architecture . ".deb";

	if ($opt_F or ($version gt $max_version)) {
		# delete all previous versions of files in the repository with the same packagename,
		# architecture in the destination
		system("rm -f " . $destination . "/" . $packagename . "*" . $architecture . ".deb");
	

		# make standard name and move
		system("dpkg-name -o " . $origarchive . " > /dev/null 2>&1");

		#display message for move debpackage or build and move
		if ($status eq "debpackage") {
			# original file was a debpackage copy it
			print "debpackage: ", $origarchive, " -> $destination/$archive\n";
			system ("cp " . $archive . " " . $destination);
		} else {
			# original file was extracted from subversion or git build it and move it
			print "$status:  ", $origarchive, " -> $destination/$archive\n";
			system ("mv " . $archive . " " . $destination);
		}
		# chmod of file in archive to 0666
		my $pname = $destination . "/" . $archive;
		chmod (0666, $pname);
	} else {
		# version of new file < existing file
		# file is not inserted
		print "$archive not inserted $version <= $max_version\n";
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

	# change to working directory
	chdir $workdir;

	# build the package and move it to the debian archive
	# check if a package requires a source tarball
	# getsource returns:
	# returns 1 if tarball sucessfully included in package
	# returns 2 if no source required, there may or may not be a postinst
	# returns 3 if sourcefile name defined in postinst but not the version
	# returns 4 if version defined in postinst but not the source name
	# returns 5 if source name and version defined but no source file found

	my $gsrc = getsource($package);
	if ($gsrc == 1) {
		print "$package: $sourcefile included\n"
	} elsif ($gsrc == 3) {
		# source file name defined but no version
		print "$package: source name found but not version: skiping\n";
		return;
	} elsif ($gsrc == 4) {
		# source version defined in postinst but not source file name
		print "$package: source version found but not source file name: skipping\n";
		return;
	} elsif ($gsrc == 5) {
		# source and version defined but file not found
		print "$package: $sourcefile defined but not found: skipping\n";
		return;
	}
	# build the package
	my $rc = system("dpkg-deb -b " . $package . " >/dev/null");
	# check if build was successful
	if ($rc == 0) {
		# debian package name = package.deb
		my $debpackage = $package . ".deb";

		# move it to the tree
		movearchivetotree($debpackage, $packagervs);
	} else {
		# control file in DEBIAN directory is not valid or does not exist
		print "control file of $package is not valid\n";
	}
}

sub usage {
    print "usage: builddebiantree [options] filelist\
-b backup public and secret key to : \"pubkeyfile secretkeyfile\" if blank use defaults $pubkeyfile $secretkeyfile\
-k import public key from \"pubkeyfile\" if blank defaults to $pubkeyfile\
-K import secret key from \"secretkeyfile\" if blank defaults to $secretkeyfile\
-l list debian packages in subversion\
-p [\"pkg1 pkg2 ...\"] extract package latest release from subversion -> build -> add to distribution tree\
-t [\"pkg1 pkg2 ...\"] extract package from trunk/root in subversion, build->add to archive tree\
-g [\"pkg1 pkg2 ...\"] extract package from git project branch, build->add to tree\
-d [\"pkg1 pkg2 ...\"] extract package from git dev branch, build->add to tree\
-r [\"dir1 dir2 ...\"] recurse directory for deb packages list containing full paths, build -> add to archive\
-F force package to be inserted in tree regardless of version\
-x destination path of archive default: $debianroot\
-a edit /etc/apt/sources to include new debhome\
-s scan packages to make Packages\
-S full path of subversion default: $subversion\
-G full path of git repo, default: $gitrepopath\
-f full path filename to be added\
-w set working directory: $workingdir\
-V print version and exit\
-R reset back to defaults and exit\n";
    exit(0);

}

# default values
$version = 2.45;
$configFile = "bdt.rc";
$dist = "home";
@all_arch = ("amd64", "i386", "armhf", "arm64");
$workingdir = "/tmp/debian";
$subversion = "file:///mnt/svn/debian";
$gitrepopath = "https://github.com/rob54321";
$debianroot = "/mnt/hdd/debhome";
$sourcefile = undef;

# get config file now, so that command line options
# can override them if necessary
getconfig;
$pubkeyfile = $debianroot . "/publickeyFile.gpg";
$secretkeyfile = $debianroot . "/secretkeyFile.gpg";

# if no arguments given show usage
my $no_arg = @ARGV;

# check if -b has an argument list after it.
# if not insert default arguments			

################## testing ##################
# print "before: @ARGV\n";
defaultparameter();
# print "after:  @ARGV\n";

# get command line options
getopts('aFVt:k:K:b:hS:lp:r:x:d:sf:w:Rg:G:');

# set up destinaton path of archive if given on command line
if ($opt_x) {
	$debianroot = $opt_x;
	# strip any trailing /
	$debianroot =~ s/\/$//;
	        
     # set flag to say a change has been made
     $config_changed = "true";
}

# edit /etc/apt/sources to include new dehome location
if ($opt_a) {
	# sources.list contains
	# deb file:///mnt/hdd/debhome home main
	# delete existing line
	system("sed --in-place=.bak1 -e '/debhome/d' /etc/apt/sources.list");
	# add current debian root
	system("sed --in-place=.bak2 -e '\$ a\\deb file://$debianroot home main' /etc/apt/sources.list");
}

# print version and exit
if ($opt_V) {
	print "version $version\n";
	exit 0;
}

# reset by deleting config file and exit
if ($opt_R) {
	unlink($configFile);
	print "deleted config file\n";
	exit 0;
}

# set the git repository path if changed
if ($opt_G) {
	$gitrepopath = $opt_G;
	$config_changed = "true";
}

# set subversion respository path
if ($opt_S) {
        $subversion = $opt_S;
        
        # set flag to say a change has been made
        $config_changed = "true";
}

# set variables after config is fetched
# so that command line options can take precedence over config file
$debianpool = $debianroot . "/pool";

# set working directory if changed
if ($opt_w) {
    $workingdir = $opt_w;
        
        # set flag to say a change has been made
        $config_changed = "true";
}

# save config file if it has changed
writeconfig if $config_changed;



#make directories if they do not exist
mkpath($debianroot) if ! -d $debianroot;
mkpath($debianpool) if ! -d $debianpool;
mkpath($workingdir) if ! -d $workingdir;

# make Packages directories if they don't exist
foreach my $architem (@all_arch) {
  	my $packagesdir = $debianroot . "/dists/" . $dist . "/main/binary-" . $architem;
   	mkpath($packagesdir) if ! -d $packagesdir;
}	

# backup up keys
# public key is written in armor format
# secret key is binary
# keys are written to default files if -b has no parameters
if ($opt_b) {

	# get full path names for the public and secret keys
	($pubkeyfile, $secretkeyfile) = split /\s+/, $opt_b;
		
	# create their directories if they do not exist
	# print "pubkey is in " . dirname($pubkeyfile) . "\n";
	# print "secret key is in " . dirname($secretkeyfile) . "\n";
	mkpath(dirname($pubkeyfile)) if ! -d dirname($pubkeyfile);
	mkpath(dirname($secretkeyfile)) if ! -d dirname($secretkeyfile);

	my $backuppub = "gpg --output ". $pubkeyfile . " --export --armor";
	system($backuppub) == 0 or die "$backuppub failed: $?\n";

	my $backupsec = "gpg --output ". $secretkeyfile . " --export-secret-keys --export-options backup";
	system($backupsec) == 0 or die "$backupsec failed: $?\n";
	print "backed up public key to: " . $pubkeyfile . "\n";
	print "backed up secret key to: " . $secretkeyfile . "\n";

}

# import public key
# the key is added to apt so archives can be read.
if ($opt_k) {
	my $command = "apt-key add " . $opt_k;
	system($command);
}    

# import the secret key for signing
if ($opt_K) {
	my $command = "gpg --import " . $opt_K;
	system($command);
}

# list all packages
if ($opt_l) {
    my $command = "svn -v list " . $subversion;
    system($command);
}

# set up subversion export command
# ensure $subversion is appended by /
$subversion = $subversion . "/" unless $subversion =~ /\/$/;

my $subversioncmd = "svn --force -q export " . $subversion;

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
		my $rc = system("svn list " . $subversion . $package . "/trunk > /tmp/svn.log 2>&1");
		$trunk = "/" unless $rc == 0;
    		my $command = $subversioncmd . $package . $trunk . " " . $workingdir . "/" . $package . " 1>/tmp/svn.log 2>/tmp/svnerror.log";
	    	if (system($command) == 0) {
			print "exported " . $subversion . $package . $trunk . "\n";
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
				print "exported " . $subversion . $package . "/release/" . $release . "\n";
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
if ($opt_g) {
    	removeworkingdir;
	# checkout each package in list $opt_t is a space separated string
	my @package_list = split /\s+/, $opt_g;
	my $gitclone = "git clone --single-branch --depth 1 --no-tags ";

	# add a final / to gitrepopath if one does not exist
	$gitrepopath = $gitrepopath . "/" unless $gitrepopath =~ /\/$/;
	
	foreach my $package (@package_list) {
		print "\n";
		print "--------------------------------------------------------------------------------\n";
		my $projectrepo = $gitrepopath . "$package" . "\.git";
    		my $command = $gitclone . "-b " . $package . " " . $projectrepo . " " . $workingdir . "/" . $package . " 1>/tmp/git.log 2>/tmp/giterror.log";

	    	if (system($command) == 0) {
			print "cloned: " . $gitrepopath . $package . "/.git" . " -- " . $package . " branch\n";
	    		# remove .git directory
    			system("rm -rf " . $workingdir . "/" . $package . "/.git");

    			# remove the readme file and .gitignore
    			unlink "$workingdir" . "/" . "$package" . "/README.md";
    			unlink "$workingdir" . "/" . "$package" . "/.gitignore";

			# build the package and move it to the tree
			buildpackage($workingdir, $package, "git");
		} else {
			my $error = `cat /tmp/giterror.log`;
			print "$error\n";
		}
	}
}

# export a package from git, development branch, build it and insert into the repository
# export to depth 1 and delete .git directory
if ($opt_d) {
    	removeworkingdir;
	# checkout each package in list $opt_t is a space separated string
	my @package_list = split /\s+/, $opt_d;
	my $gitclone = "git clone --single-branch --depth 1 --no-tags ";

	# add a final / to gitrepopath if one does not exist
	$gitrepopath = $gitrepopath . "/" unless $gitrepopath =~ /\/$/;
	
	foreach my $package (@package_list) {
		print "\n";
		print "--------------------------------------------------------------------------------\n";
		my $projectrepo = $gitrepopath . "$package" . "\.git";
    		my $command = $gitclone . "-b dev " . $projectrepo . " " . $workingdir . "/" . $package . " 1>/tmp/git.log 2>/tmp/giterror.log";

	    	if (system($command) == 0) {
			print "cloned: " . $gitrepopath . $package . "/.git -- dev branch\n";
	    		# remove .git directory
    			system("rm -rf " . $workingdir . "/" . $package . "/.git");

    			# remove the readme file and .gitignore
    			unlink "$workingdir" . "/" . "$package" . "/README.md";
    			unlink "$workingdir" . "/" . "$package" . "/.gitignore";
    			
			# build the package and move it to the tree
			buildpackage($workingdir, $package, "git");
		} else {
			my $error = `cat /tmp/giterror.log`;
			print "$error\n";
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

# if no options or h option print usage

if ($opt_h or ($no_arg == 0)) {
	usage;
	# exit
	exit 0;
}
