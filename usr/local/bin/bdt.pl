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
	
	# check if link is a link
	if ( -l $link) {
		# get original file that link points to
		$original = readlink $link;
		
		# if file is a tar file untar it
		if ($original =~ /.tar.gz$/) {
			# .tar.gz file untar it
			system("tar -xvzf " . $original);
		}
		elsif ($original =~ /.bin$/) {
			# .bin file execute it
			system($original);
		}
		else {
			# copy the file or directory to here
			print "cp -a " . $original . " " . $parentdir . "\n";
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
	
	if ($insert_file eq "true") {
		# delete previous versions of files in the repository with the same packagename, architecture in the destination
		system("rm -fv " . $destination . "/" . $packagename . "*" . $architecture . ".deb");
	
    	if ($status eq "rename") {
			# make standard name and move
			system("dpkg-name -o " . $archive . " > /dev/null 2>&1");
	
			# archive name has changed to standard name
			$archive = dirname($archive) . "/". $packagename . "_". $version . "_" . $architecture . ".deb";
    	}
       
    	#display message for move debpackage or build and move
    	if ($status eq "debpackage") {
    		print "debpackage ", basename($archive), " -> ", $destination, "\n";
    		system ("cp " . $archive . " " . $destination);
    	} else {
    		print "source     ", basename($archive), " -> ", $destination, "\n";
	    	system ("mv " . $archive . " " . $destination);
    	}
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
    
    # for each .deb file process it
    if( -f $filename) {
		# move archive to debian dist tree and create dirs
		# if file is a .deb file and arch is defined
		# then only move for given arch
		if ($arch && ($filename =~ /.deb$/)) {
			# get arch of package
			$currentarch = getpackagefield($filename, "Architecture");
			if (($filename =~ /.deb$/) && ($currentarch eq $arch || $currentarch eq "all")) {
				movearchivetotree($filename, "debpackage");
			}
    	} else {
    		# arch is undefined move all .deb files to archive
    		if ($filename =~ /.deb$/) {
    			movearchivetotree($filename, "debpackage");
    		}
    	}
    }
	# a directory was found
	# check if it has DEBIAN/control in it
	if ( -f $filename . "/" . "/DEBIAN/control" ) {
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
		if ($filename =~ /-live$/) { insertContents $filename; }

		system("dpkg -b " . $currentdir . " >/dev/null 2>&1");

		$debname = $filename . ".deb";

		movearchivetotree($debname, "rename");
	
		# do not descend futher.
		$File::Find::prune = 1;
	}
}


# main entry point
# if no options print message
if (! $ARGV[0]) {
    print "usage: builddebiantree [options] filelist\
-e extract all from subversion -> build all -> add to distribution tree\
-l list debian packages in repository\
-p extract package list from subversion -> build -> add to distribution tree\
-r recurse directory list containing archives, build -> add to repository\
-a architecture i386 or amd64 default i386\
-x destination path of archive default: /mnt/linux/mydebian\
-s scan packages to make Packages\
-d distribution etch or lenny or squeeze, testing. Default: lenny\
-S full path of subversion repository default: /mnt/linux/jbackup/svn/debian\n";
    exit();
}
# default values
$dist = "lenny";
@all_arch = ("amd64", "i386");
$workingdir = "/tmp/debian";
$repository = "file:///mnt/linux/jbackup/svn/debian/";
$debianroot = "/mnt/linux/mydebian";

# get command line options
getopts('S:a:d:elp:r:x:d:s');

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

# set the architecture
if ($opt_a) {
    $arch = $opt_a;
}

# set up destinaton if given on command line
if ($opt_x) {
    	$debianroot = $opt_x;
}

# set up values of directories
$debianpool = $debianroot . "/pool";

#mkdir directories
system("mkdir -p " . $debianroot) if ! -d $debianroot;
system("mkdir -p " . $debianpool) if ! -d $debianpool;
system("mkdir -p " . $workingdir) if ! -d $workingdir;
foreach $arch (@all_arch) {
  	$packagesdir = $debianroot . "/dists/" . $dist . "/main/binary-" . $arch;
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
    @package_list = split / /, $opt_p;
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
	@directory_list = split / /, $opt_r;
	foreach $directory (@directory_list) {
    	die "cannot open $directory" if ! -d $directory;

    	# recurse down dirs and move all
    	find \&add_archive, $directory;
	}
}
# make Packages file
if ($opt_s) {

    #change to debian root
    chdir $debianroot;

	# arch is defined then scan only for that arch, else do for all_arch
	if($arch) {
		system("dpkg-scanpackages -m -a " . $arch . " pool > dists/" . $dist . "/main/binary-". $arch . "/Packages");
		makeCompressedPackages($arch);
	} else {
		foreach $arch (@all_arch) {
			system("dpkg-scanpackages -m -a " . $arch . " pool > dists/" . $dist . "/main/binary-". $arch . "/Packages");
			makeCompressedPackages($arch);
		}
	}
     
    # make the release file
    chdir $debianroot . "/dists/" . $dist;
    unlink("Release");
    system("apt-ftparchive -o=APT::FTPArchive::Release::Components=main -o=APT::FTPArchive::Release::Codename=lenny -o=APT::FTPArchive::Release::Origin=Debian -o=APT::FTPArchive::Release::Suite=stable -o=APT::FTPArchive::Release::Label=Debian -o=APT::FTPArchive::Release::Description=\"my stuff\" -o=APT::FTPArchive::Release::Architectures=\"i386 amd64\" release . > ../Release");
    system("mv ../Release .");
}

