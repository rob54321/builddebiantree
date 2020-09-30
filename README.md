# builddebiantree
source for a debian package that builds debian repositories -- perl

This is a perl script which builds a debian repository with all the necessary files
so that it can be added to /etc/apt/sources.list on a debian/ubuntu linux machine.
packages can be extracted from git or subversion for building and then inserted into the repository

Debian package files can also be stored in the repository.
The gpg public and private keys can also be backed up and restored.

bdt.pl -h displays all options.
