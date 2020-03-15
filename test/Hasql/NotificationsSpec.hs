module Hasql.NotificationsSpec (main, spec) where

import Test.Hspec
import Test.QuickCheck

import Hasql.Notifications

-- `main` is here so that this module can be run from GHCi on its own.  It is
-- not needed for automatic spec discovery.
main :: IO ()
main = hspec spec

spec :: Spec
spec =
  describe "toPgIdenfier" $
    it "enclose text in quotes doubling existing ones" $
      fromPgIdentifier (toPgIdentifier "some \"identifier\"") `shouldBe` "\"some \"\"identifier\"\"\""