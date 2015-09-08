#!/usr/bin/perl

# this programme exports all debian source packages from svn and
# builds the debian packages, places then in the debian tree, builds the
# Packages file, updates apt-get.
use File::Basename;
use File::Find;
use Getopt::Std;
use Cwd;
use File::Glob ':glob';

# sub to replace a link with the files it points to.
# this is used for the live system since files
# cannot be installed during the building of a live system.
sub replaceLink {
	my($link) = $File::Find::name;
	
	# store current dir
	my($currentdir) = cwd;
	
	# get parent dir of link
	$parentdir = dirname($link);
	
	# check if link is a link and it ends in .lnk
	if ( (-l $link) && ($link =~ /\.lnk$/)) {
		# get original file that link points to
		$original = readlink $link;
		
		# if file is a tar file untar it
		if ($original =~ /\.tar.gz$/) {
			# .tar.gz file untar it
			system("tar -xpszf " . $original);
		}
		elsif ($original =~ /\.bin$/) {
			# .bin file execute it
			system($original);
		}
		else {
			# copy the file or directory to here
			print "including: $original \n";
			system("cp -a " . $original . " " . $parentdir);
		}
		# stop descending
		$File::Find::prune = 1;
		
		# remove the link
		unlink($link);
	}
}

# sub to insert the contents of packages for the live system.
# the name of the directory in which the package resides must be
# appended by -live.
# the first paramter is the full directory name
sub insertContents {
	my($filename) = $_[0];
	
	# search for all links in sub directories of filename
	find \&replaceLink, $filename;
	
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
	system("cp Packages P");
	system("gzip -f Packages");
	system("mv P Packages");
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
# second parameter is status = debpackage | rename
# debpackage means the archive is in standard form and needs to be moved
# rename means the archive must be renamed to standard form and then moved.
# all destination directories are created
# destination = debianpool / section / firstchar / packagename
# any architecture is moved.
sub movearchivetotree {
	my($archive, $status) = @_;

	# get section to use as first dir under pool
	$section = getpackagefield($archive, "Section");

	# get package name
	$packagename = getpackagefield($archive, "Package");
	$version = getpackagefield($archive, "Version");
	$architecture = getpackagefield($archive, "Architecture");
		
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
	@rep_files = <*$architecture.deb>;
	$insert_file = "true";
	
	# if the version of the found file is less than all the versions in the repository
	# do not insert
	foreach $file (@rep_files) {
		# compare versions
		$version_in_repository = getpackagefield($file, "Version");
		if ($version le $version_in_repository) {
			$insert_file = "false";
		}
	}
	chdir $currentdir;
	
	if ($force eq "true" || $insert_file eq "true") {
		# delete previous versions of files in the repository with the same packagename, architecture in the destination
		system("rm -f " . $destination . "/" . $packagename . "*" . $architecture . ".deb");
	
		if ($status eq "rename") {
				# make standard name and move
				system("dpkg-name -o " . $archive . " > /dev/null 2>&1");
		
				# archive name has changed to standard name
				$archive = dirname($archive) . "/". $packagename . "_". $version . "_" . $architecture . ".deb";
		}

		#display message for move debpackage or build and move
		if ($status eq "debpackage") {
			print "debpackage ", basename($archive), "\n";
			system ("cp " . $archive . " " . $destination);
		} else {
			print "source     ", basename($archive), "\n";
			system ("mv " . $archive . " " . $destination);
		}
		# chmod of file in archive to 0666
		$pname = $destination . "/" . basename($archive);
		chmod (0666, $pname);
	}
}

# sub to determine if a control file is valid or not
# returns true if valid, false otherwise
# the file is checked to see if there is a Package: Version: Maintainer: Description: fields
# if the control file is in linux source it is invalid.
sub isControlFileValid {
	$controlfile = $_[0];
	my($package,$version,$maintainer,$description) = (0, 0, 0, 0);
	
	# if control file is in a linux-source directory ignore it
	if ($controlfile =~ /linux-source/i) {
		print "invalid control file: $controlfile\n";
		return 0;
	}
	
	# open file for reading
	open( CONTROLFILE, '<', $controlfile) or die $!;
	while (<CONTROLFILE>) {
		$package = 1 if /Package:/;
		$version = 1 if /Version:/;
		$maintainer = 1 if /Maintainer:/;
		$description = 1 if /Description:/;
	}
	close CONTROLFILE;
	
	if ($package and $version and $maintainer and $description) {
		return 1;
	} else {
		print "invalid control file: $controlfile\n";
		return 0;
	}
}
# add_archive will recursively move all .deb files to the debian repository
# it will also check each directory for  DEBIAN/control file. If this file exists
# the package will be built and the archive will be saved in the same directory
# as the archive directory. The archive is renamed by movearchivetotree when insserted
# into the repository.
sub add_archive {
	# get current selection if it is a file
	$filename = $File::Find::name;
	$currentworkingdir = $_;
    
	# for each .deb file process it but not in linux-source
	if( -f $filename && ($filename !~ /linux-source/)) {
		# move archive to debian dist tree and create dirs
		# if file is a .deb file and arch is defined
		# then only move for given arch
		if ($arch && ($filename =~ /\.deb$/)) {
			# get arch of package
			$currentarch = getpackagefield($filename, "Architecture");
			if (($filename =~ /\.deb$/) && ($currentarch eq $arch || $currentarch eq "all")) {
				movearchivetotree($filename, "debpackage");
			}
		} else {
			# arch is undefined move all .deb files to archive
			if ($filename =~ /\.deb$/) {
				movearchivetotree($filename, "debpackage");
			}
		}
	}
	# a directory was found
	# check if it has DEBIAN/control in it
	elsif ( -T ($filename . "/" . "/DEBIAN/control")) {

		# verify that this is a valid control file
		if (isControlFileValid($filename . "/" . "DEBIAN/control")) {

			# this is a debian package build it
			$parentdir = dirname($filename);
			$currentdir = basename($filename);

			# if arch is defined and it the source arch then build and move
			# get architecture from control file
			if ($arch) {
				$arch_found = "false";
				open( CONTROL, '<', $filename . "/" . "DEBIAN/control") or die $!;
				while (<CONTROL>) {
					if (/Architecture: *$arch/ || /Architecture: *all/) {
						$arch_found = "true";
					}
				}
				if ($arch_found eq "false") {$File::Find::prune = 1; return}
			}
			# if we are in the build directory
			if ($currentworkingdir eq ".") {
				# in build directory change to parent to build
				chdir $parentdir;
			}
			
			# if the directory name in which the package resides is appended by "-live"
			# then all links must be downloaded into the package directory before building
			# it may also be necessary to untar files.
			# if ($filename =~ /-live$/) { insertContents $filename; }
			insertContents $filename;

			$rc = system("dpkg -b " . $currentdir . " >/dev/null 2>&1");
			if ($rc != 0) {
				print "error in $currentdir\n";
				exit;
			}
			$debname = $filename . ".deb";

			movearchivetotree($debname, "rename");
		
			# do not descend futher.
			$File::Find::prune = 1;
		}
	}
}

sub usage {
    print "usage: builddebiantree [options] filelist\
-e extract all from subversion -> build all -> add to distribution tree\
-l list debian packages in repository\
-p [\"pkg1 pkg2 ...\"] extract package list from subversion -> build -> add to distribution tree\
-r [\"dir1 dir2 ...\"] recurse directory list containing full paths, build -> add to repository\
-a architecture [i386|amd64|armhf]  default nothing\
-x destination path of archive default: $debianroot\
-s scan packages to make Packages\
-d distribution [debian|ubuntu|common|rpi]	Default: $dist\
-S full path of subversion repository default: $subversion\
-f full path filename to be added\
-F force insertion of package into repository default: $force\n";
    exit();

}
# main entry point
# default values
$dist = "none";
$rpiarch = "armhf";
@all_arch = ("amd64", "i386", "armhf");
$workingdir = "/mnt/hdint/tmp/debian";
$subversion = "/home/robert/svn";
$repository = "file://" . $subversion . "/debian/";
$debianroot = "/mnt/hdd/mydebian";
$force = "false";


# if no arguments given show usage
if (! $ARGV[0]) {
	usage;
}

# get command line options
getopts('hFS:a:d:elp:r:x:d:sf:');

# if no options or h option print usage
if ($opt_h) {
	usage;
}


# set force option to force a package to be inserted into mydebian
if ($opt_F) {
	$force = "true";
}
# set subversion respository
if ($opt_S) {
	$repository = "file://" . $opt_S . "/debian/";
}
$exportcommand = "svn --force -q export " . $repository;

# list all packages
if ($opt_l) {
    $command = "svn -v list " . $repository;
    system($command);
}

# set the distribution
if ($opt_d) {
    $dist = $opt_d;
}

# if distribution is rpi then arch must be armhf
if ($dist eq "rpi") {
    $arch = $rpiarch;
}

# set the architecture, if dist is rpi the arch is armhf
if (($opt_a) and ($dist ne "rpi")) {
    $arch = $opt_a;
}


# check a valid distribution was given
if (! (($dist eq "ubuntu") || ($dist eq "debian") || ($dist eq "common") || ($dist eq "rpi"))){
	print "$dist: is not a valid distribution\n";
	exit;
}

# check for invalid combination of dist and arch
if ((($dist eq "ubuntu") and ($arch eq $rpiarch)) or (($dist eq "debian") and ($arch eq $rpiarch))) {
    print "invalid combination of distribution and architecture\n";
    exit;
}

# set up destinaton if given on command line
if ($opt_x) {

    	$debianroot = $opt_x;
}

# set up values of directories
$debianpool = $debianroot . "/pool/$dist";

#mkdir directories
system("mkdir -p " . $debianroot) if ! -d $debianroot;
system("mkdir -p " . $debianpool) if ! -d $debianpool;
system("mkdir -p " . $workingdir) if ! -d $workingdir;
foreach $architem (@all_arch) {
  	$packagesdir = $debianroot . "/dists/" . $dist . "/main/binary-" . $architem;
   	system("mkdir -p " . $packagesdir) if ! -d $packagesdir;
}	

    
# checkout all debian packages from svn/debian, build and place in tree
if ($opt_e) {
    # export all debian packages in svn/debian to working directory
    $command = $exportcommand . " " . $workingdir;
    system($command);

    find \&add_archive, $workingdir;
    removeworkingdir;
}

if ($opt_p) {
	# empty working dir incase
    removeworkingdir;
    # checkout each package in list $opt_p is a space separated string
    @package_list = split /\s+/, $opt_p;
    foreach $package (@package_list) {
    	$command = $exportcommand . $package . " " . $workingdir . "/" . $package;
    	system($command);
    }
    find \&add_archive, $workingdir;
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

# make Packages file
if ($opt_s) {

	#change to debian root
	chdir $debianroot;

	# arch is defined then scan only for that arch, else do for all_arch
	if($arch) {
                print "dist = $dist :: arch = $arch\n";
		system("dpkg-scanpackages -m -a " . $arch . " $debianpool > dists/" . $dist . "/main/binary-". $arch . "/Packages");
		makeCompressedPackages($arch);
	} else {
                # if dist is common scan for all architectures, else scan for i386 and amd64
                if ($dist eq "common") {
                    @scan_arch = @all_arch;
                } else {
                    @scan_arch = qw/i386 amd64/;
                }
		foreach $architem (@scan_arch) {
                        print "dist = $dist :: arch = $architem\n";
			system("dpkg-scanpackages -m -a " . $architem . " pool/$dist > dists/" . $dist . "/main/binary-". $architem . "/Packages");
			makeCompressedPackages($architem);
		}
	}

	# make the release file
	chdir $debianroot . "/dists/" . $dist;
	unlink("Release");
	if ($arch eq $rpiarch) {
            system("apt-ftparchive -o=APT::FTPArchive::Release::Components=main -o=APT::FTPArchive::Release::Codename=" . $dist . " -o=APT::FTPArchive::Release::Origin=Debian -o=APT::FTPArchive::Release::Suite=stable -o=APT::FTPArchive::Release::Label=Debian -o=APT::FTPArchive::Release::Description=\"my stuff\" -o=APT::FTPArchive::Release::Architectures=$rpiarch release . > ../Release");
        } else {
            system("apt-ftparchive -o=APT::FTPArchive::Release::Components=main -o=APT::FTPArchive::Release::Codename=" . $dist . " -o=APT::FTPArchive::Release::Origin=Debian -o=APT::FTPArchive::Release::Suite=stable -o=APT::FTPArchive::Release::Label=Debian -o=APT::FTPArchive::Release::Description=\"my stuff\" -o=APT::FTPArchive::Release::Architectures=\"i386 amd64\" release . > ../Release");
        }
	system("mv ../Release .");
}

