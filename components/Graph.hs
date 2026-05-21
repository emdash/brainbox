{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE ExtendedDefaultRules #-}

-- | This file contains optimized implementations of graph functions.
--
-- It turns out that bash is just slow at some things, particularly
-- command substitutions, so it proved necessary to implement some
-- functions in python once the database grew beyond about 700
-- nodes. The initial port to python sped things up considerably.
--
-- This code has been ported from Python to Haskell, with long-term
-- maintenance and correctness the primary goal, as well as for
-- interactive mode to escape from the constraints of FZF, which has
-- been pushed to its limits. This file is starting off as a straight
-- port of the existing python implementation, with gradual migration
-- in mind.
--
-- Since it still needs to fit into the shell-based architecture, the
-- top-level interface is still in presented in terms of command-line
-- filters of streams of node IDs that can be invoked from gtd.sh.
--
-- Once the migration is complete, then a substantial refactoring can
-- be done to simplify / optimize this code, while preserving
-- correctness.
--
-- XXX: write proper stack / cabal build file for this
-- list of external dependencies:
-- - split
-- - conduit (to replace python generators)
-- - MissingH (strip)
module Brainbox.Graph where

-- local imports
import Util

-- 3rd party
import Conduit
import Data.List.Split
import Data.String.Utils

-- standard lib imports
import Control.Monad
import Control.Exception
import Data.Foldable
import Data.List
import Data.Map (Map)
import qualified Data.Map as Map
import Data.Maybe
import Data.Set (Set)
import qualified Data.Set as Set
import Debug.Trace
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
newtype Id = Id String deriving (Eq, Ord, Show)

-- | A node datum identifier.
newtype Datum = Datum String deriving Eq

-- | An adjacency-list graph representation.
type Graph a = Map a [a]

-- | The type of edge, for display purposes
data EdgeType
  = Explicit
  | Subtask
  | Leaf
  | Sibling
  | Suspect

-- | A general graph edge.
type Edge = (Id, Id)

-- | A graph edge annotated with a type for display.
type TypedEdge = (Id, Id, EdgeType)

-- | A set of graph edges
type EdgeList = [Edge]

-- | A set of edges for dot output
type TypedEdgeList = [TypedEdge]

-- | A canonical edge set
data EdgeSet = Contexts | Dependencies

-- | An effectful predicate over node Ids.
type Predicate = Env -> Id -> IO Bool

-- | An effectful predicate which also considers an edgelist.
type EdgePredicate = Env -> Id -> EdgeList -> IO Bool

-- | Type of Intermediate node Id which distinguishes start nodes
data INode = Node String | Start String

-- | Type of intermediate edges
type IEdge = (INode, INode, EdgeType)

-- | The current state of a node
data State
  = New
  | Todo
  | Done
  | Wait
  | Someday
  | Dropped
  | Info
  | Focus
  | Context
  deriving (Show, Eq, Ord)

-- | Result of a fallible operation
type Result a = IO (Either IOException a)

-- | Parse an edge set from a user-supplied string
-- Some shorthand names are also allowed here.
parseEdgeSet :: String -> Maybe EdgeSet
parseEdgeSet "contexts"     = Just Contexts
parseEdgeSet "ctx"          = Just Contexts
parseEdgeSet "dependencies" = Just Dependencies
parseEdgeSet "dep"          = Just Dependencies
parseEdgeSet _              = Nothing

-- | Get the canonical path for an edge set
canonical :: EdgeSet -> FilePath
canonical Contexts = "contexts"
canonical Dependencies = "dependencies"

-- | Parse the node state from the DB representation.
parseState :: String -> Maybe State
parseState "NEW"     = Just New
parseState "TODO"    = Just Todo
parseState "DONE"    = Just Done
parseState "WAIT"    = Just Wait
parseState "SOMEDAY" = Just Someday
parseState "DROPPED" = Just Dropped
parseState "INFO"    = Just Info
parseState "FOCUS"   = Just Focus
parseState "CONTEXT" = Just Context
parseState _         = Nothing

-- | Parse an edge from a string
--
-- the expected format is u:v
parseEdge :: String -> Maybe Edge
parseEdge edge = case splitOn ":" edge of
  [u, v] -> Just (Id u, Id v)
  _      -> Nothing

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

-- | Try to Read the Datum from the given node id
readDatum :: Env -> Datum -> Id -> Result String
readDatum env (Datum d) (Id i) =
  let path = env.node_dir ++ "/" ++ i ++ "/" ++ d
  in try $ readFile path

-- | Read the Datum from the given node id
--
-- Like `readDatum`, but returns `[no contents]` on error, which is
-- useful in some contexts.
readDatum' :: Env -> Datum -> Id -> IO String
readDatum' env datum id = do
  result <- readDatum env datum id
  pure $ case result of
    Left _ -> "[no contents]"
    Right val -> val

-- | Get the given task contents, preserving errors.
readContents :: Env -> Id -> Result String
readContents env id = readDatum env (Datum "contents") id

-- | Get the given task contents, ignoring errors.
readContents' :: Env -> Id -> IO String
readContents' env id = readDatum' env (Datum "contents") id

-- | Get the task state, if it exists and is valid.
taskState :: Env -> Id -> IO (Maybe State)
taskState env id = do
  result <- readDatum env (Datum "state") id
  pure $ case result of
    Left  _   -> Nothing
    Right val -> parseState $ strip val

-- | A top-level filter which filters according to node state.
--
-- Those whose state is in the given set are considered valid.
filterState :: Set State -> Env -> Handle -> IO ()
filterState states env handle = filterNodes env handle pred
  where
    pred :: Predicate
    pred env id = do
      state <- taskState env id
      pure $ case state of
        Nothing -> False
        Just state -> Set.member state states

-- | Print the given node id to stdout.
printId :: Id -> IO ()
printId (Id id) = putStrLn id

-- | Print the union of the two input file handle stdout.
union :: Handle -> Handle -> IO ()
union lhs rhs = do
  lhs <- readIds lhs
  rhs <- readIds rhs
  for_ (Data.List.union lhs rhs) printId

-- | Return all the nodes in the database
nodes :: Env -> IO [Id]
nodes env = do
  ids <- listDirectory env.node_dir
  pure $ Id <$> ids

-- | Read the subtasks datum for the given node
readSubtasks :: Env -> Id -> IO [String]
readSubtasks env id = do
  result <- readDatum env (Datum "subtasks") id
  pure $ case result of
    Left _    -> []
    Right val -> lines val

-- | Read the explicit edges from the database
readEdges :: Env -> EdgeSet -> IO EdgeList
readEdges env edges =
  let path = env.state_dir ++ "/" ++ canonical edges
  in do
    raw <- listDirectory path
    pure $ mapMaybe parseEdge raw

-- | Group input into clusters of serial tasks
subtaskGroups :: Env -> Id -> IO [[Id]]
subtaskGroups env id = do
  st <- readSubtasks env id
  return $ (Id <$>) <$> splitOn [""] st

-- | A helper function for subtaskEdges
--
-- This will link to the start node of any node listed in the given project set.
subtaskEdge :: Id -> INode -> EdgeType -> Set String -> IEdge
subtaskEdge (Id u) v kind projects =
  if Set.member u projects
  then (Start u, v, kind)
  else (Node  u, v, kind)

-- | Generate the edges for a set of subtask groups
subtaskEdges :: Id -> [[Id]] -> Set String -> ConduitT () IEdge IO ()
subtaskEdges (Id node) groups projects = do
  let start_node = Start node

  when (groups == []) $ do
    yield (Node node, start_node, Leaf)

  for_ groups $ \group -> do
    case group of
      [] -> yield (Node node, start_node, Leaf)
      [Id single] -> do
        yield (Node node, Node single, Subtask)
        yield $ subtaskEdge (Id single) start_node Leaf projects
      (p@(Id prev) : rest) -> do
        yield (Node node, Node prev, Subtask)
        loop p rest
        where
          loop :: Id -> [Id] -> ConduitT () IEdge IO ()
          loop prev [] = yield $ subtaskEdge prev start_node Leaf projects
          loop prev (next@(Id n) : rest) = do
            yield $ subtaskEdge prev (Node n) Sibling projects
            loop next rest


-- | Get all the subtasks of a project.
--
-- This will filter the blank lines separating subtask groups.
getSubtasks :: Env -> Id -> IO [Id]
getSubtasks env id = subtaskGroups env id >>= pure . concat

-- | Read the given edge set from the database.
edgeList :: EdgeSet -> IO [Edge]
edgeList _ = error "not implemented"

-- | Read

-- | Main entry point.
main :: IO ()
main = do
  env  <- getEnvState
  args <- getArgs

  case args of
    ("filter_state" : states) -> case validateStates states of
      Left  err    -> error err
      Right states -> filterState (Set.fromList states) env stdin
    ["subtasks", node] -> do
      subtasks <- getSubtasks env (Id node)
      for_ subtasks printId
    _ -> putStrLn "not implemented"
  where
    validateStates states = validate states parseState onErr
    onErr invalid = "Invalid state: " ++ invalid
