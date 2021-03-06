{ cabal, aeson, aws, base16Bytestring, base64Bytestring
, blazeBuilder, byteable, conduitExtra, cryptohash, httpConduit
, httpTypes, mtl, optparseApplicative, resourcet, scientific, text
, time, unorderedContainers, vector, xmlConduit
}:

cabal.mkDerivation (self: {
  pname = "aws-ec2";
  version = "0.2.2";
  sha256 = "1jlm6a4mb3mzzvql8llnvci4qd8imf58m681iqhcw1qq6hy56srl";
  isLibrary = true;
  isExecutable = true;
  buildDepends = [
    aeson aws base16Bytestring base64Bytestring blazeBuilder byteable
    conduitExtra cryptohash httpConduit httpTypes mtl
    optparseApplicative resourcet scientific text time
    unorderedContainers vector xmlConduit
  ];
  meta = {
    homepage = "https://github.com/zalora/aws-ec2";
    description = "AWS EC2/VPC, ELB and CloudWatch client library for Haskell";
    license = self.stdenv.lib.licenses.bsd3;
    platforms = self.ghc.meta.platforms;
  };
})
