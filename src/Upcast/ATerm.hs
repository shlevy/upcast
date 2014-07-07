{-# LANGUAGE OverloadedStrings #-}

module Upcast.ATerm (
  parse
, valueForKeyPath
, valueForKeyPathS
, Value(..)
) where

import Prelude hiding (takeWhile)

import Control.Applicative

import Data.ByteString.Char8 hiding (takeWhile, split)
import Data.Text hiding (cons, takeWhile)
import Data.Text.Encoding (decodeUtf8)
import qualified Data.HashMap.Strict as HM
import qualified Data.Vector as V

import Data.Aeson.Types (Value(..), object)
import Data.Attoparsec.ByteString.Char8 hiding (parse)

parse = parseOnly value

valueForKeyPath :: [Text] -> Value -> Maybe Value
valueForKeyPath keys o@(Object h) =
    case keys of
      (x:xs) -> HM.lookup x h >>= valueForKeyPath xs
      [] -> return o
valueForKeyPath [] o = return o
valueForKeyPath (_:_) _ = Nothing

valueForKeyPathS = valueForKeyPath . split (== '.')

value :: Parser Value
value = do
  w <- peekChar'
  case w of
    '{' -> set
    '[' -> list
    '"' -> String <$> str
    '.' -> String <$> path
    '/' -> String <$> path
    'f' -> string "false" *> pure (Bool False)
    't' -> string "true" *> pure (Bool True)
    'n' -> string "null" *> pure Null
    _ | isDigit w -> Number <$> scientific
    _ | isAlpha_ascii w -> String <$> identifier
      | otherwise -> fail "???"

set :: Parser Value
set = do
    char '{'
    pairs <- many' stuff
    skipSpace
    char '}'
    return $ object pairs
  where
    stuff = do
      skipSpace
      String k <- key
      skipSpace
      char '='
      skipSpace
      v <- value
      skipSpace
      char ';'
      return (k, v)

list :: Parser Value
list = do
    char '['
    skipSpace
    elems <- many (skipSpace *> value)
    skipSpace
    char ']'
    return $ Array $ V.fromList elems

key :: Parser Value
key = String <$> choice [ identifier, path, str ]

str :: Parser Text
str = do
    char '"'
    contents <- takeTill (== '"')
    char '"'
    return $ decodeUtf8 contents

path :: Parser Text
path = do
    contents <- takeTill (\x -> isSpace x || inClass ";=" x)
    return $ decodeUtf8 contents

identifier :: Parser Text
identifier = do
    h <- satisfy (inClass "a-zA-Z_")
    t <- takeWhile (inClass "a-zA-Z0-9-_")
    return $ decodeUtf8 $ cons h t
