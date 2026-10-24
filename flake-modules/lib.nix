{ lib, ... }:

{
  _module.args.flakelib = import ../lib { inherit lib; };
}
