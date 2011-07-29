# restfully-addons

Some additional helpers for RESTful APIs, to deal with SSH connections or
other protocols.

Long-term goal is to add support for these protocols into Restfully.

## Installation

    $ gem install restfully-addons

## Usage

Just require the library you need in your scripts. For instance, requiring
addons for the BonFIRE API would be done as follows:

    require 'restfully'
    require 'restfully/addons/bonfire'
    
    # your code

## Authors

* Cyril Rohr <cyril.rohr@inria.fr>
