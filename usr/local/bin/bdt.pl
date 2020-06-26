#!/usr/bin/perl

# this programme exports all debian source packages from svn and
# builds the debian packages, places then in the debian tree, builds the
# Packages file, updates apt-get.
use File::Basename;
use File::Find;
use Getopt::Std;
use Cwd;
use File::Glob;

#!/usr/bin/perl -w

# insert a default string into a list at the given index
# move the elements to the right of the index, one position to the right.
# insert the string at the index +1
sub insertstring {
	my $index = $_[0];
	# max index
	my $maxindex = $#ARGV;
	for ( my $i = $maxindex; $i >= $index; $i--) {
		my $newi = $i + 1;
		$ARGV[$newi] = $ARGV[$i];
	}
	# insert default string at index
	$ARGV[$index] = $pubkey . " " . $secretkey;
}

# this sub operates on the list @ARGV
# it search for the switch -b
# if -b is not followed by two arguments, it inserts the default arguments after -b.
# this is done so -b can be supplied with arguments
# or no arguments, in which case the 2 defaults will be inserted
# no parameters are passed and none are returned.
# @ARGV is altered if -b has no parameters
sub defaultparameter {
	

	# index of position of -b
	my $i = 0;
	foreach my $param (@ARGV) {
		# check for a -b and that it is not the last parameter
		if ($param eq "-b") {
			if ($i < $#ARGV) {
				# -b has been found at $ARGV[$i] and it is not the last parameter
				# if the next parameter is a switch -something
				# then -b has no arguments
				# check if next parameter is a switch
				if ($ARGV[$i+1] =~ /^-/) {
					# -b is followed by a switch and is not the last switch
					# insert the 2 default filenames as a string at index $i+1
					$index = $i + 1;
					insertstring($index);
				}
			} else {
				# -b is the last index then the default parameters for -b must be appended
				$index = $i + 1;
				insertstring($index); 
			}
		}
		# increment index counter
		$i++;
	}
} 

# sub to write config file of parameters that have changed.
# the hash %config contains the key value pairs of the changed variables
# all three vars workingdir, subversion and debianroot are written
# some may not have changed, then the default values are written
# format is variable value
sub writeconfig {
    # set up hash to save
    $config{"workingdir"} = $workingdir;
    $config{"subversion"} = $subversion;
    $config{"debianroot"} = $debianroot;
    
    open OUTFILE, ">$configFile";
    foreach $key (keys %config) {
        print OUTFILE "$key $config{$key}\n";
    }
    close OUTFILE;
}

# sub to get config file if it exists
# if the config file exists, defaults will be read from the file
# if there is no config file the original defaults will be used.
sub getconfig {
    # check if file exists
    if ( -e $configFile) {
        # display file
        open INFILE,"<$configFile";
        
        # file format:
        # var_name=value
        # read file into hash and set values
        while (<INFILE>) {
            $workingdir = (split " ", $_)[1] if /workingdir/;
            $subversion = (split " ", $_)[1] if /subversion/;
            $debianroot = (split " ", $_)[1] if /debianroot/;
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
	@command = ("dpkg-deb -f ", $archive, $field);
	$field = `@command`;
	chomp $field;

	# return control field from package
	return $field;
}

# movearchivetotree:
# first parameter is full path to the archive
# second parameter is status = debpackage | subversion
# debpackage means the archive is a debpackage, rename it to standard form and copy to archive
# subversion means the archive was exported from subversion, built, renamed to standard form and moved to archive
# all destination directories are created
# destination = debianpool / section / firstchar of archive / packagename
# any architecture is moved.
sub movearchivetotree {
	my($origarchive, $status) = @_;

	# get section to use as first dir under pool
	$section = getpackagefield($origarchive, "Section");

	# get package name
	$packagename = getpackagefield($origarchive, "Package");
	$version = getpackagefield($origarchive, "Version");
	$architecture = getpackagefield($origarchive, "Architecture");

#print "movearchivetotree: new file: $origarchive $status $packagename $version $architecture\n";
		
	# make dir under pool/firstletter of packagename/packagename
	# get first character of string
	$firstchar = substr($packagename, 0, 1);

	# make directory
	$destination = $debianpool . "/" . $section . "/" . $firstchar . "/" . $packagename;
	system("mkdir -p " . $destination) if ! -d $destination;

	# compare the version of the file being inserted to the existing versions
	# in the destination directory for the same architecture.
	# Do not insert an older version, delete and older version in the repository
	# get version of package in the archive
	$currentdir = cwd;
	chdir $destination;
	# make a list of all files with same package name and architecture
	@repository_files = glob("$packagename*$architecture.deb");

	# There may be multiple files with different versions in the repository
	# if there are two or more files then check that the file being inserted
	# has a version greater than the maximum version
	# set maximum version
	$max_version = 0;

	# find the maximum version
	foreach $file_in_repository (@repository_files) {
		# compare versions
		$version_in_repository = getpackagefield($file_in_repository, "Version");
		$max_version = $version_in_repository if $max_version < $version_in_repository;
#print "move: max_version = $max_version\n";

	}
	
	# Insert file to repository if the new version > than the version in the repository
	chdir $currentdir;
	if ($version > $max_version) {
		# delete all previous versions of files in the repository with the same packagename,
		# architecture in the destination
		system("rm -f " . $destination . "/" . $packagename . "*" . $architecture . ".deb");
	

		# make standard name and move
		system("dpkg-name -o " . $origarchive . " > /dev/null 2>&1");

		# archive name has changed to standard name
		$archive = $packagename . "_". $version . "_" . $architecture . ".deb";

		#display message for move debpackage or build and move
		if ($status eq "debpackage") {
			# original file was a debpackage copy it
			print "debpackage: ", $origarchive, " -> $destination/$archive\n";
			system ("cp " . $archive . " " . $destination);
		} else {
			# original file was extracted from subversion and built, move it
			print "subversion source:  ", $origarchive, " -> $destination/$archive\n";
			system ("mv " . $archive . " " . $destination);
		}
		# chmod of file in archive to 0666
		$pname = $destination . "/" . $archive;
		chmod (0666, $pname);
	} else {
		# version of new file < existing file
		# file is not inserted
		print "$origarchive not inserted $version <= $max_version\n";
	}
}

# add_archive will recursively copy all .deb files to the debian repository
# the package will be renamed to standard form by movetoarchivetree
sub add_archive {
	# get current selection if it is a file
	$fullfilename = $File::Find::name;
	$filename = $_;
        $currentworkingdir = $File::Find::dir;
#print "add_archive: filename = $filename\n";
        
	# for each .deb file, not directory, process it but not in linux-source
	if( -f $filename && ($filename !~ /linux-source/)) {
		# move archive to debian dist tree and create dirs
		if ($filename =~ /\.deb$/) {
#print "add_archive: movearchivetotree ($filename, debpackage)\n";
			print "\n";
			print "--------------------------------------------------------------------------------\n";
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
	my($workdir, @package_list) = @_;

	# change to working directory
	chdir $workdir;

	# for each package, build the package
	foreach $package (@package_list) {

		# build the package
		print "\n";
		print "--------------------------------------------------------------------------------\n";
		print "building package $package\n";
		$rc = system("dpkg-deb -b " . $package . " >/dev/null");
		# check if build was successful
		if ($rc == 0) {
			# debian package name = package.deb
			my $debpackage = $package . ".deb";

			# move it to the tree
			movearchivetotree($debpackage, "subversion");
		} else {
			# control file in DEBIAN directory is not valid or does not exist
			print "control file of $package is not valid\n";
		}

	}
}

sub usage {
    print "usage: builddebiantree [options] filelist\
-b backup public and secret key to : \"file1 file2\" if blank use defaults $pubkey $secretkey\
-e extract all from subversion -> build all -> add to distribution tree\
-l list debian packages in repository\
-p [\"pkg1 pkg2 ...\"] extract package list from subversion -> build -> add to distribution tree\
-r [\"dir1 dir2 ...\"] recurse directory list containing full paths, build -> add to repository\
-x destination path of archive default: $debianroot\
-s scan packages to make Packages\
-S full path of subversion repository default: $subversion\
-f full path filename to be added\
-w set working directory: $workingdir\
-R reset back to defaults and exit\n";
    exit();

}
# main entry point
# default values
$configFile = "/root/.bdt.rc";
$dist = "home";
@all_arch = ("amd64", "i386", "armhf");
$workingdir = "/mnt/hdint/tmp/debian";
$subversion = "/mnt/svn";
$repository = "file://" . $subversion . "/debian/";
$debianroot = "/mnt/hdd/debhome";
$debianpool = $debianroot . "/pool";
$pubkey = $debianroot . "/keyFile";
$secretkey = $debianroot . "/secretkeyFile.gpg";

# if no arguments given show usage
$no_arg = @ARGV;
if ($no_arg == 0) {
	$no_args = "true";
}

# check if -b has an argument list after it.
# if not insert default arguments			

################## testing ##################
# print "before: @ARGV\n";
defaultparameter();
# print "after:  @ARGV\n";

# get command line options
getopts('b:hS:elp:r:x:d:sf:w:R');

################# testing ###################
# print "after getopts\n";
# print "no of args $no_arg\n";
# print "ARGV: @ARGV \n";

# foreach my $item (@ARGV) {
#	print "item: $item\n";
# }
#############################################

# if no options or h option print usage
if ($opt_h or ($no_args eq "true")) {
	usage;
	# exit
	exit 0;
}

# backup up keys
# public key is written in armor format
# secret key is binary

if ($opt_b) {
	($pubkey, $secretkey) = split /\s+/, $opt_b;
	my $backuppub = "gpg --output ". $pubkey . " --export --armor";
	print "backing up public key to: " . $pubkey . "\n";
	system($backuppub) == 0 or die "@backuppub failed: $?\n";

	my $backupsec = "gpg --output ". $secretkey . " --export-secret-keys --export-options backup";
	print "backing up secret key to: " . $secretkey . "\n";
	system($backupsec) == 0 or die "@backupsec failed: $?\n";
}

# reset by deleting config file and exit
if ($opt_R) {
    unlink($configFile);
    print "deleted config file\n";
    exit 0;
}

# get config file now, so that command line options
# can override them if necessary
getconfig;

# set subversion respository path
if ($opt_S) {
        $subversion = $opt_S;
        
        # add change to hash for saving
        $config{"subversion"} = $opt_S;
        
        # set flag to say a change has been made
        $config_changed = "true";
}

# list all packages
if ($opt_l) {
    $command = "svn -v list " . $repository;
    system($command);
}

# set up destinaton path of repository if given on command line
if ($opt_x) {

    	$debianroot = $opt_x;
        # add change to hash for saving
        $config{"debianroot"} = $opt_x;
        
        # set flag to say a change has been made
        $config_changed = "true";
}

# set working directory if changed
if ($opt_w) {
    $workingdir = $opt_w;
        # add change to hash for saving
        $config{"workingdir"} = $opt_w;
        
        # set flag to say a change has been made
        $config_changed = "true";
}

# save config file if it has changed
writeconfig if $config_changed;



# set up commands
$exportcommand = "svn --force -q export " . $repository;

#mkdir directories
system("mkdir -p " . $debianroot) if ! -d $debianroot;
system("mkdir -p " . $debianpool) if ! -d $debianpool;
system("mkdir -p " . $workingdir) if ! -d $workingdir;

# make Packages directories if they don't exist
foreach $architem (@all_arch) {
  	my $packagesdir = $debianroot . "/dists/" . $dist . "/main/binary-" . $architem;
   	system("mkdir -p " . $packagesdir) if ! -d $packagesdir;
}	

    
# checkout all debian packages from svn/debian, build and place in tree
if ($opt_e) {
	# local variable
	my @package_list;
	# work in the working directory
	chdir $workingdir;

	# empty the working directory
	removeworkingdir;

	# export all debian packages in svn/debian to working directory
	$command = $exportcommand . " " . $workingdir;
	system($command);

	# make a list of all directories in working directory.
	# each directory is a package. Do no descend
	@files = glob("*");
	foreach my $dir (@files) {
		push (@package_list, $dir) if -d $dir;
	}
	# build the packages
	buildpackage($workingdir, @package_list);	
}

if ($opt_p) {
	# empty working dir incase
    removeworkingdir;
    # checkout each package in list $opt_p is a space separated string
    my @package_list = split /\s+/, $opt_p;
    foreach $package (@package_list) {
    	$command = $exportcommand . $package . " " . $workingdir . "/" . $package;
    	system($command);
    }
    # build the package and move it to the tree
    buildpackage($workingdir, @package_list);
    removeworkingdir;
}
# process a dir recursively and copy all debian i386 archives to tree
# search each dir for DEBIAN/control. If found build package.
# the opt_r can be a space separated directory list
if ($opt_r) {
	@directory_list = split /\s+/, $opt_r;
	foreach $directory (@directory_list) {
    		die "cannot open $directory" if ! -d $directory;

	    	# recurse down dirs and move all
    		find \&add_archive, $directory;
	}
}

# add one specific file to the archive
if ($opt_f) {
	$fileAdd = $opt_f;
	die "$fileAdd is not .deb file or could not be opened\n" if (! (($fileAdd =~ /\.deb/) and (open FHANDLE, "< $fileAdd")));
	close FHANDLE;
	
	movearchivetotree($fileAdd, "debpackage");			
}

# scan pool and make Packages file
if ($opt_s) {

	#change to debian root
	chdir $debianroot;

	# there is only one distribution ie $debianroot / dists / home 
	# which contains amd64, i386 and armhf
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
}

