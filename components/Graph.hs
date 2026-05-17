{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE RecordWildCards #-}

module Brainbox.Graph where

import Util

import Control.Monad.Reader
import Data.Foldable
import Data.List
import Data.Map (Map)
import qualified Data.Map as Map
import System.Environment
import System.Directory
import System.IO

-- | Holds the relevant environment variables for this module.
data Env = Env {
  state_dir     :: String,
  bucket_dir    :: String,
  node_dir      :: String,
  font          :: String,
  background    :: String,
  rankdir       :: String,
  show_contexts :: Bool,
  show_virtual  :: Bool,
  show_subtasks :: Bool,
  show_deps     :: Bool,
  debug_edges   :: Bool
}

-- | A node ID.
newtype Id = Id String deriving Eq

-- | A node datum identifier.
newtype Datum = Datum String deriving Eq

-- | An adjacency-list graph representation.
type Graph = Map Id [Id]

-- | A graph edge.
type Edge = (Id, Id)

-- | A set of graph edges
type EdgeList = [Edge]

-- | A canonical edge set
data EdgeSet = Contexts | Dependencies

-- | An effectful predicate over node Ids.
type Predicate = Env -> Id -> IO Bool

-- | An effectful predicate which also considers an edgelist.
type EdgePredicate = Env -> Id -> EdgeList -> IO Bool

-- | Parse an edge set from a user-supplied string
-- Some shorthand names are also allowed here.
parseEdgeSet :: String -> Maybe EdgeSet
parseEdgeSet "contexts"     = Just Contexts
parseEdgeSet "ctx"          = Just Contexts
parseEdgeSet "dependencies" = Just Dependencies
parseEdgeSet "dep"          = Just Dependencies
parseEdgeSet _              = Nothing

-- | Pull in our state from the environment
getEnvState :: IO Env
getEnvState = do
  bucket_dir    <- getEnv     "BUCKET_DIR"
  state_dir     <- getEnv     "STATE_DIR"
  node_dir      <- getEnv     "NODE_DIR"
  font          <- getEnvStr  "GTD_GRAPH_FONT"          "monospace"
  background    <- getEnvStr  "GTD_GRAPH_BG"            "white"
  rankdir       <- getEnvStr  "GTD_GRAPH_RANKDIR"       "TB"
  show_contexts <- getEnvBool "GTD_GRAPH_SHOW_CONTEXTS" True
  show_deps     <- getEnvBool "GTD_GRAPH_SHOW_DEPS"     True
  show_virtual  <- getEnvBool "GTD_GRAPH_SHOW_VIRTUAL"  True
  show_subtasks <- getEnvBool "GTD_GRAPH_SHOW_SUBTASKS" True
  debug_edges   <- getEnvBool "GTD_GRAPH_DEBUG_EDGES"   False
  return Env{..}

-- | True if the given node Id has the given datum
has :: Datum -> Predicate
has (Datum datum) env (Id id) = do
  let path = env.node_dir ++ "/" ++ id ++ "/" ++ datum
  doesPathExist path

-- | Read all the ids from the given handle.
--
-- This assumes that the handle will print one Id per line, and that
-- each line contains a valid node ide.
readIds :: Handle -> IO [Id]
readIds handle = do
  contents <- hGetContents handle
  return $ Id <$> lines contents

-- | Filter nodes from the input file handle to stdout.
filterNodes :: Env -> Handle -> Predicate -> IO ()
filterNodes state handle predicate = do
  ids <- readIds handle
  filter_ ids
  where
    filter_ :: [Id] -> IO ()
    filter_ []            = pure ()
    filter_ (id@(Id x) : xs) = do
      pred <- predicate state id
      case pred of
        True -> putStrLn x
        False -> pure ()
      filter_ xs

-- | Like filterNodes, but also considers the given edge set.
--
-- Constructing edge sets is potentially expensive, so we avoid it
-- mostly.
filterNodesWithEdges
  :: Env
  -> Handle
  -> EdgeSet
  -> EdgePredicate
  -> IO ()
filterNodesWithEdges state handle edges predicate = do
  edges <- edgeList edges
  filterNodes state handle (\state id -> predicate state id edges)

-- | Read bucket contents into a list.
readBucket :: Env -> String -> IO [Id]
readBucket state bucket =
  let
    path = state.bucket_dir ++ "/" ++ bucket
  in do
    ids <- listDirectory path
    return $ Id <$> ids

-- | Print the given node id to stdout.
printId :: Id -> IO ()
printId (Id id) = putStrLn id

-- | Print the union of the two input file handle stdout.
union :: Handle -> Handle -> IO ()
union lhs rhs = do
  lhs <- readIds lhs
  rhs <- readIds rhs
  for_ (Data.List.union lhs rhs) printId

-- | Read the given edge set from the database.
edgeList :: EdgeSet -> IO [Edge]
edgeList _ = error "not implemented"

-- | Main entry point.
main :: IO ()
main = do
  state <- getEnvState
  args <- getArgs
  putStrLn "not implemented"
