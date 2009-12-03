#!/usr/bin/perl
# this programme exports all debian source packages from svn and
# builds the debian packages, places then in the debian tree, builds the
# Packages file, updates apt-get.
use File::Basename;
use File::Find;
use Getopt::Std;
use Cwd;

# remove working dir
sub removeworkingdir {
    # remove working dir
    chdir $workingdir;
    chdir "..";
    system("rm -rf *");
}

# given an archive name this function returns the package name or architecture
sub getpackagefield {
    $archive = $_[0];
    $field = $_[1];

    # get the package name from the control file
    @command = ("dpkg-deb -f", $archive, $_[1]);
    $field = `@command`;
    chomp $field;

    return $field;
}

# the given archive is added to the distribution tree
# if status is rename the package.deb renamed to package_version.deb
# the package was build from source of exported from the repository.
# if status is debpackage then it is only moved to the archive.
# all the correct directories are created if necesary
# the name is then added to the override file
# parameters passed: archive name, 'rename' to rename package to standard name
sub movearchivetotree {
    my($archive);

    # archive name in current directory where we are presently
    $archive = $_[0];
    $status = $_[1];
    
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
    mkdir $debianpool . "/" . $section;
    mkdir $debianpool . "/" . $section . "/" . $firstchar;
    mkdir $destination;
    

    if ($status eq "rename") {
		# make standard name and move
		system("dpkg-name -o " . $archive . " > /dev/null 2>&1");
	
		# archive name has changed to standard name
		$archive = dirname($archive) . "/". $packagename . "_". $version . "_" . $architecture . ".deb";
    }
       
    #display message for move debpackage or build and move
    if ($status eq "debpackage") {
    	print "debpackage ", basename($archive), " -> ", $destination, "\n";
    } else {
    	print "source     ", basename($archive), " -> ", $destination, "\n";
    }
    
    system ("mv " . $archive . " " . $destination);

}

# add_archive will recursively move all .deb files to the debian repository
# if a directory exists then it is checked for DEBIAN/control file
# if found the package will be build and inserted into the repository
# a directory must be passed to this function
sub add_archive {
    # get current selection if it is a file
    $filename = $File::Find::name;
    
    # for each .deb file process it
    if( -f $filename) {
		# get the extension of the file name
		($file, $dir, $ext) = fileparse($filename, qr/\.[^.]*/);

		# move archive to debian dist tree and create dirs
		# if file is a .deb file
		if ($ext eq ".deb") {
	    	$architecture = getpackagefield($filename, "Architecture");
			movearchivetotree($filename, "debpackage");
		}
    }
	# a directory was found
	# check if it has DEBIAN/control in it
	if ( -f $filename . "/" . "/DEBIAN/control" ) {
		# this is a debian package build it
		$parentdir = dirname($filename);
		$currentdir = basename($filename);
		
		# if we are in the build directory
		if ($_ eq ".") {
			# in build directory change to parent to build
			chdir $parentdir;
		}
		$dir = cwd;
		# print "add_archive: cwd $dir : dpkg -b $currentdir \n";

		system("dpkg -b " . $currentdir . " >/dev/null 2>&1");

		$debname = $filename . ".deb";

		movearchivetotree($debname, "rename");
	
		# do not descend futher.
		$File::Find::prune = 1;
	}
}

# buildtree will recurse a directory and build all the source packages if
# necesary and pack them into a Debian distribution tree in the correct
# directories.
sub buildtree {
    # open a directory and list dirs inside
    opendir (DEB, $workingdir) or die "no dir: $!";
    chdir $workingdir;

    # descend into each subdirectory under the working dir DEB.
    foreach $name (readdir(DEB)) {
	if ($name ne ".." and $name ne "."){
	    print "Processing: ", $name, "\n";

	    chdir $name or die "cannot change to ",$name, ": $!";
	    
            # untar file if it exists
	    if (-e "contents.tar.gz") {
		system("tar -xpzf contents.tar.gz") ;

		# remove tar file
		unlink "contents.tar.gz";
	    }
	    # change back
	    chdir ".." or die "cannot go back";

	    # build debian package
	    system("dpkg -b " . $name . " >/dev/null 2>&1");

	    # get name of package from control file
	    $archive = $name . ".deb";

	    # move archive to tree
	    movearchivetotree($archive, "rename");
	}
    }
    closedir(DEB);
    removeworkingdir();
}

# main entry point
# if no options print message
if (! $ARGV[0]) {
    print "usage: builddebiantree [options] filelist\
\t-e extract all from subversion -> build all -> add to distribution tree\
\t-l list debian packages in repository\
\t-p extract package from subversion -> build -> add to distribution tree\
\t-r recurse directory containing archives, build -> add to repository\
\t-a architecture i386 or amd64 default i386\
\t-x destination path of archive\
\t-s scan packages to make Packages\
\t-d distribution etch or lenny or squeeze, testing. Default lenny\n";
    exit();
}
# default values
$dist = "lenny";
$arch = "i386";
$workingdir = "/mnt/hdint/robert/tmp/debian";
$repository = "file:///home/robert/svn/debian/";
$exportcommand = "svn --force -q export " . $repository;

# get command line options
getopts('a:d:elp:r:x:d:s');

# list all packages and exit
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

# set up destinaton
if ($opt_x) {
    $debianroot = $opt_x . "/";
    # set up values of directories
    $debianpool = $debianroot . "pool";
    $packagesdir = $debianroot . "dists/" . $dist . "/main/binary-" . $arch;

    #mkdir directories
    system("mkdir -p " . $debianroot) if ! -d $debianroot;
    system("mkdir -p " . $debianpool) if ! -d $debianpool;
    system("mkdir -p " . $workingdir) if ! -d $workingdir;
    system("mkdir -p " . $packagesdir) if ! -d $packagesdir;
}

    
# checkout all debian packages, build and place in tree
if ($opt_e) {
    # checkout debian packages
    $command = $exportcommand . " " . $workingdir;
    system($command);

    buildtree();
}

if ($opt_p) {
    # checkout only the one package

    $command = $exportcommand . $opt_p . " " . $workingdir . "/" . $opt_p;
    system($command);

    buildtree();
}
# process a dir recursively and copy all debian i386 archives to tree
# search each dir for DEBIAN/control. If found build package.
if ($opt_r) {
    die "cannot open $opt_r" if ! -d $opt_r;

    # recurse down dirs and move all archives to deb dist tree
    find \&add_archive, $opt_r;
}
# make Packages file
if ($opt_s) {

    #change to debian root
    chdir $debianroot;

    # make Packages file for debian distribution
    system("dpkg-scanpackages -m -a " . $arch . " pool > dists/" . $dist . "/main/binary-". $arch . "/Packages");
    
    # make Packages.gzip Packages.bz2
    chdir $packagesdir;
    system("cp Packages P");
    system("gzip -f Packages");
    system("mv P Packages");
    system("bzip2 -f -k Packages");

    # make the release file
    chdir $debianroot . "/dists/" . $dist;
    unlink("Release");
    system("apt-ftparchive -o=APT::FTPArchive::Release::Components=main -o=APT::FTPArchive::Release::Codename=lenny -o=APT::FTPArchive::Release::Origin=Debian -o=APT::FTPArchive::Release::Suite=stable -o=APT::FTPArchive::Release::Label=Debian -o=APT::FTPArchive::Release::Description=\"my stuff\" -o=APT::FTPArchive::Release::Architectures=\"i386 amd64\" release . > ../Release");
    system("mv ../Release .");
}

