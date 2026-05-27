{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE ExtendedDefaultRules #-}
{-# LANGUAGE RankNTypes #-}

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
-- - pipes
-- - MissingH (strip)
module Brainbox.Graph where

-- local imports
import Util

-- 3rd party
import Pipes
import qualified Pipes.Prelude as P
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
type Graph = Map INode (Set INode)

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

-- | A canonical edge set
data EdgeSet = Contexts | Dependencies

-- | An effectful predicate over node Ids.
type Predicate = Env -> Id -> IO Bool

-- | An effectful predicate which also considers an edgelist.
type EdgePredicate = Env -> Id -> [Edge] -> IO Bool

-- | Type of Intermediate node Id which distinguishes start nodes
data INode = Node String | Start String deriving (Ord, Eq, Show)

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

idOf :: Id -> String
idOf (Id x) = x

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
canonical Contexts     = "contexts"
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
-- XXX: This assumes that the handle yields one Id per line, and that
-- each line contains a valid node ID.
readIds :: Handle -> Producer Id IO ()
readIds handle = P.fromHandle handle >-> P.map Id

-- | Filter nodes from the input file handle to stdout.
filterNodes :: Env -> Predicate -> Pipe Id Id IO ()
filterNodes env predicate = P.filterM (predicate env)

{-
-- | Read the given edge set from the database.
edgeList :: Env -> EdgeSet -> IO [Edge]
edgeList env edgeset =
  let dir = env.state_dir ++ "/" ++ canonical edgeset
  in do
    edges <- listDirectory $ trace ("XXX" ++ dir) dir
    return $ mapMaybe parseEdge edges
-}

-- | Like filterNodes, but also considers the given edge set.
--
-- Constructing edge sets is potentially expensive, so the edge set is
-- explicit.
filterNodesWithEdges
  :: Env
  -> EdgeSet
  -> EdgePredicate
  -> Pipe Id Id IO ()
filterNodesWithEdges env edges predicate = do
  edges <- lift $ P.toListM $ readEdges env edges
  filterNodes env (pred edges)
  where
    pred edges env id = predicate env id edges

-- | Read bucket contents into a list.
readBucket :: Env -> String -> IO [Id]
readBucket state bucket =
  let
    path = state.bucket_dir ++ "/" ++ bucket
  in do
    ids <- listDirectory path
    return $ Id <$> ids

-- | Try to Read the Datum from the given node id
readDatum :: Env -> Datum -> Id -> Producer String IO ()
readDatum env (Datum d) (Id i) =
  let path = env.node_dir ++ "/" ++ i ++ "/" ++ d
  in do
    handle <- lift $ openFile path ReadMode
    P.fromHandle handle

-- | Flip every edge in the input stream.
flipped :: Monad m => Pipe IEdge IEdge m ()
flipped = P.map $ \(u, v, k) -> (v, u, k)

-- | Construct a graph from a Producer of edges.
adjacencyMap :: Monad m => Producer IEdge m () -> m Graph
adjacencyMap edges = P.fold insertEdge Map.empty id edges
  where
    insertEdge :: Graph -> IEdge -> Graph
    insertEdge g (u, v, _) = case Map.lookup u g of
      Nothing -> Map.insert u (Set.singleton v) g
      Just vs -> Map.insert u (Set.insert v vs) g

-- | Get the task state, if it exists and is valid.
taskState :: Env -> Id -> IO (Maybe State)
taskState env id = do
  line <- P.head $ readDatum env (Datum "state") id
  return $ Control.Monad.join $ parseState <$> line

-- | A top-level filter which filters according to node state.
--
-- Those whose state is in the given set are considered valid.
filterState :: Set State -> Env -> Pipe Id Id IO ()
filterState states env = filterNodes env pred
  where
    pred :: Predicate
    pred env id = do
      state <- taskState env id
      pure $ case state of
        Nothing -> False
        Just state -> Set.member state states

-- | Print the given node id to stdout.
printId :: Id -> IO ()
printId = putStrLn . idOf

-- | Print the union of the two input file handle stdout.
union :: Handle -> Handle -> Producer Id IO ()
union lhs rhs = do
  readIds lhs
  readIds rhs

-- | Return all the nodes in the database
nodes :: Env -> Producer Id IO ()
nodes env = do
  ids <- lift $ listDirectory env.node_dir
  each ids >-> P.map (Id . strip)

-- | Read the explicit edges from the database
readEdges :: Env -> EdgeSet -> Producer Edge IO ()
readEdges env edges =
  let path = env.state_dir ++ "/" ++ canonical edges
  in do
    raw <- lift $ listDirectory path
    each raw >-> P.mapMaybe parseEdge

-- | Group input into clusters of serial tasks
subtaskGroups :: Env -> Id -> IO [[Id]]
subtaskGroups env id = do
  lines <- P.toListM $ readDatum env (Datum "subtasks") id
  return $ (Id <$>) <$> splitOn [""] lines

-- | A helper function for subtaskEdges
--
-- This will link to the start node of any node listed in the given project set.
subtaskEdge :: Id -> INode -> EdgeType -> Map String [[Id]] -> IEdge
subtaskEdge (Id u) v kind projects =
  if Map.member u projects
  then (Start u, v, kind)
  else (Node  u, v, kind)


-- | Generate the edges for a set of subtask groups
subtaskEdges :: Id -> [[Id]] -> Map String [[Id]] -> Producer IEdge IO ()
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
          loop :: Id -> [Id] -> Producer IEdge IO ()
          loop prev [] = yield $ subtaskEdge prev start_node Leaf projects
          loop prev (next@(Id n) : rest) = do
            yield $ subtaskEdge prev (Node n) Sibling projects
            loop next rest

-- | Construct the intermediate project taskgraph.
--
-- This is the union of all subtask edges and all the explicit edges,
-- with project-level dependencies blocking the project start node.
projectSubgraph :: Env -> Map String [[Id]] -> Producer IEdge IO ()
projectSubgraph env projects = do
  edges <- lift $ P.toListM $ readEdges env Dependencies

  for (each (Map.assocs projects)) $ \(node, groups) -> do
    subtaskEdges (Id node) groups projects

  for (each edges) $ \(u, (Id v)) -> do
    yield $ subtaskEdge u (Node v) Explicit projects

-- | One iteration of merging start nodes into the graph.
mergeStartNodesIter :: Monad m => Producer IEdge m () -> Producer IEdge m ()
mergeStartNodesIter edges =
  do
    edges    <- lift $ P.toListM edges
    outgoing <- lift $ adjacencyMap (each edges)
    incoming <- lift $ adjacencyMap $ (each edges) >-> flipped
    for (each edges) $ \(u, v, kind) -> do
      let us = mergeSet u incoming
      let vs = mergeSet v outgoing
      for (each us) $ \u -> do
        for (each vs) $ \v -> do
          unless (u == v) $ yield (u, v, kind)
  where
    mergeSet :: INode -> Graph -> Set INode
    mergeSet u g = case u of
      Node  _ -> Set.singleton u
      Start _ -> fromMaybe Set.empty $ Map.lookup u g

-- | Merge start nodes back into the graph by combining their edges.
mergeStartNodes :: Monad m => Producer IEdge m () -> Producer IEdge m ()
mergeStartNodes edges = do
  edges <- lift $ P.toListM $ mergeStartNodesIter edges
  if any touchesStartNode edges
    then mergeStartNodes (each edges)
    else each edges
  where
    touchesStartNode :: IEdge -> Bool
    touchesStartNode (Start _, _, _) = True
    touchesStartNode (_, Start _, _) = True
    touchesStartNode _               = False

-- | Yield all the project nodes in the DB.
projects :: Env -> Producer Id IO ()
projects env = nodes env >-> filterNodes env (has (Datum "subtasks"))

-- | A generator which yields all dependency edges.
--
-- We have to special-case "Project" nodes to get the correct
-- graph.
--
-- Complexity arises from the "outline format" of the substasks file
-- and the naive interpretation of a tree as an explicit DAG. Outline
-- format implies:
--
--  1. Reverse ordering, with the first subtask in a group considered a leaf.
--  2. Implicit chaining, with each successive sibling depending on the previous.
--  3. Project-level dependencies implicitly block project leaves.
--
-- This requires a multi-pass approach. The first pass constructs an
-- incomplete project dag from the subtasks file for each
-- project. During this pass, we in insert virtual start nodes which
-- implicitly block the leaves of each project.
--
-- We then process the explicit edges of the graph, adjusting any
-- project-level dependencies to block to the virtual start node,
-- rather than the project node itself.
--
-- Finally, the virtual nodes are removed by merging edges with their
-- neighbors. We could skip this step, but this breaks the invariant
-- that node IDs always refer to a valid path in the DB, resulting in
-- numerous downstream issues.
--
-- Earlier approaches were simpler, but incorrectly treated
-- project-level dependencies as leaves in some cases. The intention is
-- that as a task expands into a project, any explicit dependencies it
-- might have continue to depend on the task as a whole, including its
-- transitive dependencies.
dependencies :: Env -> Bool -> Producer IEdge IO ()
dependencies env show_virtual =
  do
    nodes    <- lift $ P.toListM $ projects env
    projects <- lift $ foldM insertGroups Map.empty (idOf <$> nodes)
    if show_virtual
      then projectSubgraph env projects
      else mergeStartNodes $ projectSubgraph env projects
  where
    insertGroups :: Map String [[Id]] -> String -> IO (Map String [[Id]])
    insertGroups projects node = do
      groups <- subtaskGroups env (Id node)
      return $ Map.insert node groups projects

-- | Get the stream of edges for the given edge set.
--
-- Client code should call this function, rather than lower-level
-- functions, to ensure project subtasks are handled correctly.
edgeList :: Env -> EdgeSet -> Bool -> Bool -> Producer IEdge IO ()
edgeList env edges subtasks show_virtual = case (edges, subtasks) of
  (Dependencies, True) -> dependencies env show_virtual
  _                    -> readEdges env edges >-> P.map extend
  where
    extend :: Edge -> IEdge
    extend (Id u, Id v) = (Node u, Node v, Explicit)

-- | Get all the subtasks of a project.
--
-- This will filter the blank lines separating subtask groups.
getSubtasks :: Env -> Id -> Producer Id IO ()
getSubtasks env id = do
  groups <- lift $ subtaskGroups env id
  each $ Data.List.concat groups

-- | Result of dispatching on command arguments.
data Cmd
  -- | A node Id filter
  = Filter (Pipe Id Id IO ())
  -- | A stream of node ids, but doesn't consume from stdin.
  | Stream (Producer Id IO ())
  -- | A pipeleine run for its effect
  | Eff    (Effect IO ())
  -- | A result to be printed to stdout, with normal exit status.
  | Result String
  -- | An error messge to be printe to stderr, with failing exit status.
  | Error  String

-- | Determine which command to run based on argv.
dispatch :: Env -> [String] -> Cmd
dispatch env ("filter_state" : states) = case validateStates states of
  Left  err    -> Error err
  Right states -> Filter $ filterState (Set.fromList states) env
  where
    validateStates states = validate states parseState onErr
    onErr invalid = "Invalid state: " ++ invalid
dispatch env ["subtasks", node] = Stream $ getSubtasks env (Id node)
dispatch env ["is_project", node] =
  Filter $ has (Datum "subtasks")
dispatch env ["union", rhs] =
  Eff $ do
  rhs <- lift $ openFile rhs ReadMode
  for (Brainbox.Graph.union stdin rhs) (lift . printId)
dispatch env _ = Error "not implemented"

-- | Abstract common code for streams of nodes.
runStream :: Producer Id IO () -> IO ()
runStream stream = runEffect $ for stream (lift . printId)

-- | Abstract common code for running node filters.
runFilter :: Pipe Id Id IO () -> IO ()
runFilter pipeline = runStream (readIds stdin >-> pipeline)

-- | Main entry point.
main :: IO ()
main = do
  env  <- getEnvState
  args <- getArgs
  case dispatch env args of
    Filter f -> runFilter f
    Stream s -> runStream s
    Eff    e -> runEffect e
    Result s -> putStrLn  s
    Error  e -> error     e
