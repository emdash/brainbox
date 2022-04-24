# Installation

GtdGraph is a stand-alone shell script. There's no need to install it
in any particular location, so long as the
[dependencies](README.md#dependencies) are installed on your
system. All you need do is clone the source in your preferred
location.

## Shell Configuration

I suggest adding something equivalent to the following `bash` snippet
to your shell initialization file (if you are unsure, this is probably
`.bashrc`):

    GTD_DIR="/path/to/gtd" # change me
    if test -d "/proc/$$/cwd/gtdgraph"; then
        "${GTD_DIR}/gtd.sh" "$@"
    else
        GTD_DATA_DIR="${HOME}/.gtdgraph" "${GTD_DIR}/gtd.sh" "$@"
    fi

Where `/path/to/gtd` points to the root of this source tree.

	$ exec bash

You should now have a `gtd` command available:

	$ type gtd

Which should produce:

    gtd is a function
    gtd () 
    { 
    if test -d "/proc/$$/cwd/gtdgraph"; then
        "${GTD_DIR}/gtd.sh" "$@"
    else
        GTD_DATA_DIR="${HOME}/.gtdgraph" "${GTD_DIR}/gtd.sh" "$@"
    fi
    }

As defined above, this command will use the gtd database in your
current working directory, or fall back to the one in your home
directory if no such directory exists. In this way, you can run `gtd`
anywhere, and it will probably do the right thing.

The final step is to initialize your default database.

    $ cd
    $ gtd init

And you should be ready to roll. Any time you want to create an
independent database, simply move to a new directory (creating it if
needed), and:

    $ gtd init
