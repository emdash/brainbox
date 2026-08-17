{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE ExtendedDefaultRules #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE AllowAmbiguousTypes #-}
{-# LANGUAGE TypeApplications #-}

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
-- - text
-- - graphviz
module Brainbox.Graph where

-- local imports
import Interval qualified as I
import Interval((|-))
import DateSet qualified as DS
import JSONParser qualified as JP
import Parser qualified as Pa
import Scheduler qualified as S
import Util

-- 3rd party
import Data.List.Split
import Data.Either.Extra
import Data.Foldable.Extra
import Data.GraphViz.Types.Monadic
import Data.GraphViz.Attributes
import Data.GraphViz.Attributes.Complete qualified as C
import Data.GraphViz.Attributes.Colors qualified as Colors
import Data.GraphViz.Parsing
import Data.GraphViz.Printing
import Data.List.Extra (upper)
import Data.String.Utils
import Data.Text.Lazy qualified as T
import Data.Text.Lazy.IO qualified as TIO
import Data.Time.Clock
import Graphics.Vty qualified as Vty
import Graphics.Vty.Platform.Unix(mkVty)
import Pipes
import Pipes.Prelude qualified as P

-- standard lib imports
import Control.Monad
import Control.Exception
import Data.IORef
import Data.List
import Data.Map (Map)
import qualified Data.Map as Map
import Data.Maybe
import Data.Set (Set)
import qualified Data.Set as Set
import System.Environment
import System.Directory
import System.IO

-- | Holds the relevant environment variables for this module.
data Env = Env {
  state_dir     :: String,
  bucket_dir    :: String,
  node_dir      :: String,
  font          :: String,
  background    :: Colors.Color,
  rankdir       :: C.RankDir,
  show_contexts :: Bool,
  show_virtual  :: Bool,
  show_subtasks :: Bool,
  show_deps     :: Bool,
  debug_edges   :: Bool,
  now           :: I.DateTime
}

-- | A node datum identifier.
newtype Datum = Datum String deriving Eq

-- | An adjacency-list graph representation.
type Graph idT = Map idT (Set idT)

-- | The type of edge, for display purposes
data EdgeType
  = Explicit
  | Subtask
  | Leaf
  | Sibling
  | Suspect
  deriving (Ord, Eq, Show)

-- | A general graph edge.
type Edge idT = (idT, idT, EdgeType)

-- | A canonical edge set
data EdgeSet = Contexts | Dependencies

-- | Edge direction relative to the current node.
data Direction = Incoming | Outgoing | All

-- | An effectful predicate over node Ids.
type Predicate idT = Env -> idT -> IO Bool

-- | An effectful predicate which also considers an edgelist.
type EdgePredicate idT = Graph idT -> Predicate idT

-- | A plain node ID.
newtype Id = Id String deriving (Eq, Ord, Show)

-- | Type of Intermediate node Id which distinguishes start nodes from
-- ordinary nodes.
data INode = Node String | Start String deriving (Ord, Eq, Show)

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

-- | Retrieves string value from node ID types.
class IdOf idT where
  getId :: idT -> String
  idOf :: idT -> String
instance IdOf Id where
  getId (Id x) = x
  idOf = getId
instance IdOf INode where
  getId (Node x) = x
  getId (Start x) = x

  idOf (Node x) = x
  idOf (Start x) = x ++ "::start"

-- | Parse a direction value
parseDirection :: String -> Maybe Direction
parseDirection "incoming" = Just Incoming
parseDirection "outgoing" = Just Outgoing
parseDirection "all"      = Just All
parseDirection _          = Nothing

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
parseEdge :: String -> Maybe (Edge Id)
parseEdge edge = case splitOn ":" edge of
  [u, v] -> Just (Id u, Id v, Explicit)
  _      -> Nothing

-- | Lift an edge of plain ids to an edge of INodes.
idToINode :: Edge Id -> Edge INode
idToINode (Id u, Id v, k) = (Node u, Node v, k)

-- | Parse a dot value from a string.
--
-- This will quote all values, so that the input need not be quoted.
pdot :: ParseDot a => String -> a
pdot s = parseIt' $ T.pack $ quoted
  where
    -- hack alert!  hex colors fail to parse parse correctly when
    -- unquoted. graphviz package might be more trouble than it's
    -- worth for us.
    quoted = "\"" ++ s ++ "\""

-- | Get a dot-parsable value from an environment variable.
getEnvDot :: ParseDot a => String -> String -> IO a
getEnvDot var def = do
  val <- lookupEnv var
  return $ pdot $ fromMaybe def val

-- | Pull in our state from the environment
getEnvState :: IO Env
getEnvState = do
  bucket_dir    <- getEnv     "BUCKET_DIR"
  state_dir     <- getEnv     "STATE_DIR"
  node_dir      <- getEnv     "NODE_DIR"
  font          <- getEnvStr  "GTD_GRAPH_FONT"          "monospace"
  background    <- getEnvDot  "GTD_GRAPH_BG"            "white"
  rankdir       <- getEnvDot  "GTD_GRAPH_RANKDIR"       "TB"
  show_contexts <- getEnvBool "GTD_GRAPH_SHOW_CONTEXTS" True
  show_deps     <- getEnvBool "GTD_GRAPH_SHOW_DEPS"     True
  show_virtual  <- getEnvBool "GTD_GRAPH_SHOW_VIRTUAL"  True
  show_subtasks <- getEnvBool "GTD_GRAPH_SHOW_SUBTASKS" True
  debug_edges   <- getEnvBool "GTD_GRAPH_DEBUG_EDGES"   False
  now           <- getCurrentTime
  return Env{..}

-- | True if the given node Id has the given datum
has :: Datum -> Predicate Id
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
filterNodes :: Env -> Predicate idT -> Pipe idT idT IO ()
filterNodes env predicate = P.filterM (predicate env)

-- | Flip every edge in the input stream.
flipped :: Monad m => Pipe (Edge idT) (Edge idT) m ()
flipped = P.map $ \(u, v, k) -> (v, u, k)

-- | Construct a graph from a Producer of edges.
adjacencyMap
  :: Monad m
  => (Eq idT, Ord idT)
  => Producer (Edge idT) m ()
  -> m (Graph idT)
adjacencyMap edges = P.fold insertEdge Map.empty id edges
  where
    insertEdge g (u, v, _) = case Map.lookup u g of
      Nothing -> Map.insert u (Set.singleton v) g
      Just vs -> Map.insert u (Set.insert v vs) g

-- | Slurp in an entire graph for the given edge set
readGraph
  :: forall idT . (Eq idT, Ord idT)
  => Dependencies (Edge idT)
  => ReadEdges (Edge idT)
  => Env
  -> EdgeSet
  -> Direction
  -> IO (Graph idT)
readGraph env edges direction = adjacencyMap $ edges' direction
  where
    edges' :: Direction -> Producer (Edge idT) IO ()
    edges' Outgoing = edgeList env edges
    edges' Incoming = edgeList env edges >-> flipped
    edges' All      = do
      edgeList env edges
      edgeList env edges >-> flipped

-- | Helper for constructing predicates that rely on sets of edges.
--
-- Constructing edge sets is expensive, so we read the graph into
-- memory up-front, re-using this map for each node.
withEdges
  :: Env
  -> EdgeSet
  -> Direction
  -> EdgePredicate INode
  -> IO (Predicate INode)
withEdges env edges direction pred = do
  g <- readGraph env edges direction
  return $ pred g

-- | Read bucket contents into a list.
readBucket :: Env -> String -> IO [Id]
readBucket state bucket =
  let
    path = state.bucket_dir ++ "/" ++ bucket
  in do
    ids :: Either IOException [String] <- try $ listDirectory path
    case ids of
      Right ids -> return $ Id <$> ids
      _         -> return []

-- | Compute the datum path for the given datum
datumPath :: Env -> Datum -> Id -> String
datumPath env (Datum d) (Id i) = env.node_dir ++ "/" ++ i ++ "/" ++ d

-- | Try to Read the Datum from the given node id
readDatum :: Env -> Datum -> Id -> Producer String IO ()
readDatum env datum id = do
  handle <- lift $ openFile (datumPath env datum id) ReadMode
  P.fromHandle handle
  lift $ hClose handle

-- | Helper function to parse the value from the first line of a task datum.
withFirstLine :: (String -> Maybe a) -> Datum -> Env -> Id -> IO (Maybe a)
withFirstLine parser datum env id = do
  line :: Either IOException String <- try $ withFile (datumPath env datum id) ReadMode hGetLine
  case line of
    Left  _   -> return Nothing
    Right val -> return $ parser val

-- | Get the task contents as a stream of lines.
taskContents :: Env -> Id -> Producer String IO ()
taskContents env = readDatum env (Datum "contents")

-- | Get the first line of the task contents.
taskGloss :: Env -> Id -> IO (Maybe String)
taskGloss = withFirstLine Just (Datum "contents")

-- | Get the task state, if it exists and is valid.
taskState :: Env -> Id -> IO (Maybe State)
taskState = withFirstLine parseState (Datum "state")

-- | A top-level filter which filters according to node state.
--
-- Those whose state is in the given set are considered valid.
filterState :: Set State -> Predicate Id
filterState states env id = do
  state <- taskState env id
  return $ case state of
    Nothing -> False
    Just state -> Set.member state states

-- Print task summary to stdout
printSummary :: Env -> Maybe String -> IO ()
printSummary env delimiter =
  let d = fromMaybe " " delimiter
  in runEffect $ for (readIds stdin) $ \id -> do
    state <- lift $ taskState env id
    gloss <- lift $ taskGloss env id
    lift $ putStrLn $
         (idOf id)
      ++ d
      ++ pad 7 ' ' (fromMaybe "[no contents]" $ upper . show <$> state)
      ++ d
      ++ (fromMaybe "[no contents]" gloss)

-- | Print the given node id to stdout.
printId :: IdOf idT => idT -> IO ()
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

-- | Abstract over reading edges with different node ID types.
class ReadEdges edgeT where
  readEdges :: Env -> EdgeSet -> Producer edgeT IO ()
instance ReadEdges (Edge Id) where
  -- | Read the explicit edges from the database
  readEdges env edges =
    let path = env.state_dir ++ "/" ++ canonical edges
    in do
      raw <- lift $ listDirectory path
      each raw >-> P.mapMaybe parseEdge
instance ReadEdges (Edge INode) where
  readEdges env edges = readEdges @(Edge Id) env edges >-> P.map idToINode

-- | Group input into clusters of serial tasks
subtaskGroups :: Env -> Id -> IO [[Id]]
subtaskGroups env id = do
  lines <- P.toListM $ readDatum env (Datum "subtasks") id
  return $ (Id <$>) <$> splitOn [""] lines

-- | A helper function for subtaskEdges
--
-- This will link to the start node of any node listed in the given project set.
subtaskEdge :: Id -> INode -> EdgeType -> Map String [[Id]] -> Edge INode
subtaskEdge (Id u) v kind projects =
  if Map.member u projects
  then (Start u, v, kind)
  else (Node  u, v, kind)

-- | Generate the edges for a set of subtask groups
subtaskEdges :: Id -> [[Id]] -> Map String [[Id]] -> Producer (Edge INode) IO ()
subtaskEdges (Id node) groups projects = do
  let start_node = Start node

  when (groups == []) $ do
    yield (Node node, start_node, Leaf)

  for_ groups $ \group -> do
    -- process each group in reverse to get correct sibling
    -- dependency ordering.
    case reverse group of
      [] -> yield (Node node, start_node, Leaf)
      [Id single] -> do
        yield (Node node, Node single, Subtask)
        yield $ subtaskEdge (Id single) start_node Leaf projects
      (p@(Id prev) : rest) -> do
        yield (Node node, Node prev, Subtask)
        loop p rest
        where
          loop :: Id -> [Id] -> Producer (Edge INode) IO ()
          loop prev [] = yield $ subtaskEdge prev start_node Leaf projects
          loop prev (next@(Id n) : rest) = do
            yield $ subtaskEdge prev (Node n) Sibling projects
            loop next rest

-- | Construct the intermediate project taskgraph.
--
-- This is the union of all subtask edges and all the explicit edges,
-- with project-level dependencies blocking the project start node.
projectSubgraph :: Env -> Map String [[Id]] -> Producer (Edge INode) IO ()
projectSubgraph env projects = do
  edges <- lift $ P.toListM $ readEdges @(Edge Id) env Dependencies

  for (each (Map.assocs projects)) $ \(node, groups) -> do
    subtaskEdges (Id node) groups projects

  for (each edges) $ \(u, (Id v), _) -> do
    yield $ subtaskEdge u (Node v) Explicit projects

-- | One iteration of merging start nodes into the graph.
mergeStartNodesIter
  :: Monad m
  => Set (Edge INode)
  -> Producer (Edge INode) m ()
mergeStartNodesIter edges =
  do
    outgoing <- lift $ adjacencyMap (each edges)
    incoming <- lift $ adjacencyMap $ (each edges) >-> flipped
    for (each edges) $ \(u, v, kind) -> do
      let us = mergeSet u incoming
      let vs = mergeSet v outgoing
      for (each us) $ \u -> do
        for (each vs) $ \v -> do
          unless (u == v) $ yield (u, v, kind)
  where
    mergeSet :: INode -> Graph INode -> Set INode
    mergeSet u g = case u of
      Node  _ -> Set.singleton u
      Start _ -> fromMaybe Set.empty $ Map.lookup u g

-- | Intermediate graph type
--
-- This is a set of edges that either touches start nodes or a set
-- that provably doesn't.
type IGraph = Either (Set (Edge INode)) (Set (Edge Id))

-- | Merge start nodes back into the graph by combining their edges.
--
-- Any edge which touches a start node is replaced by a subgraph which
-- connects its neighbors in both directions.
mergeStartNodes
  :: Monad m
  => Set (Edge INode)
  -> Producer (Edge Id) m ()
mergeStartNodes edges =
  do
    edges <- lift $ P.fold collectNodes (Right Set.empty) id $ mergeStartNodesIter edges
    case edges of
      Left hasStartNodes -> mergeStartNodes hasStartNodes
      Right done -> each done
  where
    -- | Fold an edges into the set.
    --
    -- We start by assuming we have finished (Right). If our assumption is wrong, we bail (Left).
    collectNodes :: IGraph -> Edge INode -> IGraph
    collectNodes (Right g) (Node u, Node v, k) = Right $ Set.insert (Id u, Id v, k) g
    collectNodes (Right g) e                   = Left  $ Set.insert e $ Set.map idToINode g
    collectNodes (Left  g) e                   = Left  $ Set.insert e g

-- | Yield all the project nodes in the DB.
projects :: Env -> Producer Id IO ()
projects env = nodes env >-> filterNodes env (has (Datum "subtasks"))

-- | Reading dependency graph behavior varies based on the type.
--
-- | See the instance documentation for details.
class Dependencies edgeT where
  dependencies :: Env -> Producer edgeT IO ()

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
instance Dependencies (Edge INode) where
  dependencies env =
    do
      nodes    <- lift $ P.toListM $ projects env
      projects <- lift $ foldM insertGroups Map.empty (idOf <$> nodes)
      projectSubgraph env projects
    where
      insertGroups :: Map String [[Id]] -> String -> IO (Map String [[Id]])
      insertGroups projects node = do
        groups <- subtaskGroups env (Id node)
        return $ Map.insert node groups projects

-- | Instance for `Id`
--
-- Since the output cannot contain start nodes, this enforces that
-- start nodes are properly merged.
--
-- Downstream code has the invariant that node IDs always refer to a
-- valid path in the DB.
instance Dependencies (Edge Id) where
  dependencies env =
    do
      edges <- lift collect
      mergeStartNodes edges
    where
      collect :: IO (Set (Edge INode))
      collect = P.fold (flip Set.insert) Set.empty id $ dependencies @(Edge INode) env

-- | Get the stream of edges for the given edge set.
--
-- Client code should call this function, rather than lower-level
-- functions, to ensure project subtasks are handled correctly.
edgeList
  :: Dependencies edgeT
  => ReadEdges edgeT
  => Env
  -> EdgeSet
  -> Producer edgeT IO ()
edgeList env edges = case (edges, env.show_subtasks) of
  (Dependencies, True) -> dependencies env
  _                    -> readEdges env edges

-- | Get all the subtasks of a project.
--
-- This will filter the blank lines separating subtask groups.
getSubtasks :: Env -> Id -> Producer Id IO ()
getSubtasks env id = do
  groups <- lift $ subtaskGroups env id
  each $ Data.List.concat groups

-- | True if the given edge touches any of the given nodes.
--
-- The map expects raw node ids, which should not include virtual start nodes.
edgeTouches
  :: IdOf idT
  => Edge idT
  -> Map String a
  -> Bool
edgeTouches (u, v, _) nodes = (Map.member (getId u) nodes) || (Map.member (getId v) nodes)

-- | True if the given edge is completely within the given nodes.
--
-- The map expects raw node ids, which should not include virtual start nodes.
edgeContained
  :: IdOf idT
  => Edge idT
  -> Map String a
  -> Bool
edgeContained (u, v, _) nodes = (Map.member (getId u) nodes) && (Map.member (getId v) nodes)

-- | Stream of all the nodes adjacent to the given input set.
nodeAdjacent :: (Eq idT, Ord idT) => idT -> Direction -> Pipe (Edge idT) idT IO ()
nodeAdjacent node direction = forever $ do
  (u, v, _) <- await
  case direction of
    Outgoing -> when (node == u) (yield v)
    Incoming -> when (node == v) (yield u)
    All      -> when ((node == u) || (node == v)) $ do
      yield u
      yield v

-- | True if a node has any edges in the given direction.
hasAdjacent :: (Eq idT, Ord idT) => EdgePredicate idT
hasAdjacent graph _ id = do
  return $ case Map.lookup id graph of
    Nothing -> False
    Just neighbors  -> Set.size neighbors > 0

-- | Expands the input stream to include adjacent neighbors.
adjacent :: Env -> EdgeSet -> Direction -> Producer Id IO ()
adjacent env edges direction = do
  graph <- lift $ readGraph env edges direction
  readIds stdin >-> go graph
  where
    go :: Graph Id -> Pipe Id Id IO ()
    go graph = do
      id <- await
      yield id
      case Map.lookup id graph of
        Nothing        -> go graph
        Just neighbors -> do
          each neighbors
          go graph

-- | Helper to invert predicates, which is verbose because of monads.
invert :: EdgePredicate idT -> EdgePredicate idT
invert pred graph env id = do
  res <- pred graph env id
  return $ not res

invert' :: Predicate idT -> Predicate idT
invert' f env id = not <$> (f env id)

-- | True if the the given node is a next-action node.
isNext :: Graph Id -> Predicate Id
isNext g env id = do
  state_valid  <- filterState (Set.fromList [New, Todo]) env id
  case state_valid of
    True -> case Map.lookup id g of
      Nothing -> return True
      Just n  -> do
        res <- anyM (filterState (Set.fromList [New, Todo, Wait, Someday]) env) n
        return $ not res
    False -> return False

-- Get the set of nodes reachable from the given node set, for the given graph.
reachabilitySet :: Graph Id -> Set Id -> Set Id
reachabilitySet g nodes = Set.unions $ Set.map (reachable g) nodes
  where
    reachable :: Graph Id -> Id -> Set Id
    reachable g n = case Map.lookup n g of
      Nothing -> Set.empty
      Just neighbors -> Set.unions $ Set.map (reachable g) neighbors

-- A predicate which will keep only edges reachable from the given input set.
reachableFrom :: Set Id -> EdgePredicate Id
reachableFrom nodes g _ id =
  let reachable = reachabilitySet g nodes
  in return $ Set.member id reachable

-- Expands the input set to include all nodes which are reachable from it.
reachable :: Graph Id -> Pipe Id Id IO ()
reachable g = do
  nodes <- lift $ P.fold (flip Set.insert) Set.empty id $ readIds stdin
  each $ reachabilitySet g nodes

-- A debugging function which will reveal improperly linked context nodes.
danglingContexts :: Env -> Producer Id IO ()
danglingContexts env = do
  existing <- lift $ P.fold (flip Set.insert) Set.empty id $ nodes env
  for (edgeList @(Edge Id) env Contexts) $ \(u, v, _) -> do
    case (Set.member u existing, Set.member v existing) of
      (True, False) -> yield u
      (False, True) -> yield v
      _             -> pure ()

-- | Abstract over some obnoxious features of the dot API that make it
-- difficult to mix named and hex colors.
class StrColor a where
  c :: String -> a
instance StrColor Colors.ColorList where
  c s = [C.toWC $ pdot s]
instance StrColor Colors.Color where
  c s = pdot s

-- | Render one node to dot syntax
renderNode :: Env -> (String, NodeData) -> Dot String
renderNode env (id, data') =
  do
    -- also include start node when required by settings, if it exists.
    when (env.show_virtual && data'.is_project) $
      render (id ++ "::start") (label' ++ "\nΦ") C.CDS data'.state
    -- render the canonical node.
    render id label' shape' data'.state
  where
    label' = fromMaybe id data'.label
    shape' = if data'.is_project then Folder else BoxShape

    -- | use same color for fill as for border, plus font color.
    fillStroke bg fg = [C.FillColor $ c bg, C.Color $ c bg, C.FontColor $ c fg]

    -- | helper to render a single node with common style attributes
    render :: String -> String -> C.Shape -> Maybe State -> Dot String
    render id l sh st = node id
      $ style filled
      : toLabel l
      : shape sh
      : penWidth 2
      : (fromMaybe default' (colors <$> st))

    -- default color scheme for nodes of undetermined staus.
    default' = fillStroke "Gray95" "Gray50"

    -- table of colors for nodes in a known status.
    colors New     = fillStroke "DeepPink" "Black"
    colors Todo    = fillStroke "Gray95"   "Black"
    colors Done    = fillStroke "#ccffcc"  "#99cc99"
    colors Dropped = fillStroke "#ffdddd"  "#ff9999"
    colors Wait    = fillStroke "Red"      "Black"
    colors Someday = fillStroke "#ddaaff"  "Black"
    colors Info    = fillStroke "Gold"     "Black"
    colors Focus   = fillStroke "Green"    "Black"
    colors Context = fillStroke "#aaffdd"  "Black"

-- | Information needed to correctly render a node.
data NodeData = ND {
  is_project :: Bool,
  label      :: Maybe String,
  state      :: Maybe State
}

-- | Dotfile export
render
  :: forall a. (Eq a, Ord a, IdOf a, Dependencies (Edge a), ReadEdges (Edge a))
  => Env
  -> Set Id
  -> IO (Dot String)
render env selection =
  do
    -- do all our IO up-font in this block
    input    <- P.fold (flip Set.insert) selection id (readIds stdin)
    buckets  <- listDirectory env.bucket_dir >>= mapM rb
    source   <- readBucket env "source"
    target   <- readBucket env "target"
    deps     <- collectEdges $ edgeList @(Edge a)  env Dependencies
    contexts <- collectEdges $ edgeList @(Edge Id) env Contexts

    let bnodes = Control.Monad.join $ snd <$> buckets
    let nodes' = foldl (flip Set.insert) input bnodes
    data' <- foldM collectNodes Map.empty nodes'

    -- render collected data to dot format
    return $ do
      graphAttrs [
        C.RankDir env.rankdir,
        C.FontName $ T.pack env.font,
        C.BgColor $ [C.toWC env.background]]

      for_ buckets $ \(bucket, contents) -> do
        node bucket [shape House, style filled, bgColor Gray95]
        for_ contents $ \c -> do
          edge bucket (idOf c) [style dashed, color Gray]

      for_ source $ \u -> do
        for_ target $ \v -> do
          edge (idOf u) (idOf v) [style dashed, color Gray]

      for_ (Map.toList data') (renderNode env)

      when env.show_deps     $ for_ deps     $ doEdge data' Red
      when env.show_contexts $ for_ contexts $ doEdge data' Green
  where
    rb bucket = do
      contents <- readBucket env bucket
      return (bucket, contents)

    empty :: Arrow
    empty = C.AType [(C.openMod, C.Normal)]

    doEdge :: IdOf idT => Map String NodeData -> X11Color -> Edge idT -> Dot String
    doEdge nodes c e@(u, v, k) = when (edgeContained e nodes) $
      edge (idOf u) (idOf v) $ styleEdge c k

    styleEdge :: X11Color -> EdgeType -> Attributes
    styleEdge c Explicit = [style solid,  color c]
    styleEdge c Subtask  = [style dashed, color c]
    styleEdge c Leaf     = [style dashed, color c, arrowTo empty]
    styleEdge c Sibling  = [style dashed, color c, arrowTo oDot]
    styleEdge c Suspect  = [style dashed, color c, arrowTo oDiamond]

    collectEdges :: (Eq idT, Ord idT) => Producer (Edge idT) IO () -> IO (Set (Edge idT))
    collectEdges edges = P.fold (flip Set.insert) Set.empty id edges

    collectNodes :: Map String NodeData -> Id -> IO (Map String NodeData)
    collectNodes data' id@(Id i) = do
      has_subtasks <- has (Datum "subtasks") env id
      label        <- taskGloss env id
      state        <- taskState env id
      let is_project =
            case state of
              Just New     -> has_subtasks
              Just Todo    -> has_subtasks
              Just Done    -> has_subtasks
              Just Dropped -> has_subtasks
              _         -> False
      return $ Map.insert i (ND {..}) data'

-------------------------------------------------------------------------------

-- | Get the task schedule if it exists
-- XXX: would prefer either here so I could get error messges
taskSchedule :: Env -> Id -> IO (Maybe DS.DateSet)
taskSchedule = withFirstLine (eitherToMaybe . JP.fromString) (Datum "schedule")

-- | Get the task completion history if it exists
taskHistory :: Env -> Id -> IO [I.DateTime]
taskHistory env id =
  P.toListM $ readDatum env (Datum "completed") id >-> P.mapM (Pa.runM Pa.parseDateTime)

-- | Parse window args and construct command with the resulting value.
withWindow :: Env -> [String] -> (I.TimePeriod -> Cmd) -> Cmd
withWindow env w f = case S.windowArgs env.now w of
  Left err -> Error err
  Right w  -> f w

-- Scheduler classification
data Classification = Unscheduled | Event | Habit

-- | Classify node according to data
classifyNode :: Env -> Id -> IO Classification
classifyNode env id = do
  schedule <- has (Datum "schedule") env id
  if schedule
    then do
      completed <- has (Datum "completed") env id
      if completed
        then return Habit
        else return Event
    else return $ Unscheduled

data Fucked a  = Below | BBorder | Inside a | ABorder | Above

isFucked :: Int -> Int -> Int -> Fucked Int
isFucked l x u = case compare x l of
  LT -> Below
  EQ -> BBorder
  GT -> case compare x u of
    LT -> Inside $ x - l - 1
    EQ -> ABorder
    GT -> Above

-- | Print agenda view for the given window.
--
-- This will show scheduled and nscheduled activity for the given input set.
agenda :: Env -> Set Id -> IO ()
agenda env selection = do
  let dt = env.now
  let interval     = 15 * I.minute -- xxx: add to env
  let start_of_day =  8 * I.hour   -- xxx: add to env
  let end_of_day   = 22 * I.hour   -- xxx: add to env
  todo            <- newIORef []
  scheduled       <- newIORef Map.empty
  glosses         <- newIORef Map.empty
  runEffect $ for (readIds stdin) $ \id -> do
    klass <- lift $ classifyNode env id
    gloss <- lift $ taskGloss env id
    case gloss of
      Nothing -> pure ()
      Just gloss -> lift $ modifyIORef glosses (Map.insert id gloss)
    case klass of
      Unscheduled -> lift $ modifyIORef todo (id :)
      Event -> lift $ do
        ds <- taskSchedule env id
        modifyIORef scheduled $ Map.insert id $ fromJust ds
      Habit -> lift $ do
        ds <- taskSchedule env id
        modifyIORef scheduled $ Map.insert id $ fromJust ds

  scheduled' <- readIORef scheduled
  glossen <- readIORef glosses

  let ad = S.agendaDay env.now $ Map.toList scheduled'

  for_ ad.allDay $ putStrLn . show . (Map.lookup -$ glossen)

  renderSlow 200 287 $ plot glossen <$> ad.scheduled
  -- renderSlow 80 24 $ [("foo", 2, 2, 5, 5), ("bar", 10, 5, 5, 7), ("quux", 12, 7, 5, 7)]
  where
    row :: I.DateTime -> Int
    row (UTCTime _ time) = (fromEnum time) `div` 1_000_000_000_000 `div` 60 `div` 5

    col :: Int -> Int
    col slot = (width + 2) * slot

    height :: I.TimeDelta -> Int
    height td = (fromEnum td) `div` 1_000_000_000_000 `div` 60 `div` 5

    width :: Int
    width = 20

    rect label x y w h = (label, x, y, w, h)

    plot :: Map Id String -> (Id, (I.TimePeriod, Int)) -> (String, Int, Int, Int, Int)
    plot glossen (id, (I.TimePeriod s e, slot)) =
      rect
        (fromJust $ Map.lookup id glossen)
        (col slot)
        (row s)
        width
        (height $ e I.|-| s)

    shadeRect y x (label, rx, ry, w, h) =
      let lx = x - rx
          ly = y - ry
      in case (isFucked 0 lx w, isFucked 0 ly h) of
        (BBorder, BBorder) -> Just '+'
        (ABorder, BBorder) -> Just '+'
        (BBorder, ABorder) -> Just '+'
        (ABorder, ABorder) -> Just '+'
        (BBorder, Inside _) -> Just '|'
        (ABorder, Inside _) -> Just '|'
        (Inside _, BBorder) -> Just '-'
        (Inside _, ABorder) -> Just '-'
        (Inside x, Inside y) -> label !? (x + y * (w - 1))
        (Inside _, Inside _) -> Just ' '
        _ -> Nothing

    takeLast :: Maybe Char -> Maybe Char -> Maybe Char
    takeLast Nothing x = x
    takeLast x Nothing = x
    takeLast x y = y

    yToTime :: Int -> Int -> String
    yToTime w y =
      let elapsed = 5 * y
          (hours, minutes) = divMod elapsed 60
          timestr = (pad 2 '0' $ show hours) ++ (':' : (pad 2 '0' $ show minutes)) ++ " "
      in if minutes == 0
         then (replicate w '-') ++ ('\n' : timestr)
         else timestr

    renderSlow :: Int -> Int -> [(String, Int, Int, Int, Int)] -> IO ()
    renderSlow w h recs = for_ ((divMod -$ w) <$> [0..w * h]) $ \(y, x) -> do
      when (x == 0) $ putStr $ '\n' : yToTime w y
      putChar $ fromMaybe ' ' $ foldl' takeLast Nothing $ (shadeRect y x) <$> recs



-------------------------------------------------------------------------------

-- | Result of dispatching on command arguments.
--
-- Limit the number of cases we need to handle in top-level main.
data Cmd
  -- | A node Id filter
  = Filter (Predicate Id)
  -- | A filter which includes graph data.
  | EdgeFilter EdgeSet Direction (EdgePredicate Id)
  -- | A stream of node ids, but doesn't consume from stdin.
  | Stream (Producer Id IO ())
  -- | A pipeleine run for its effect
  | Eff    (IO ())
  -- | A result to be printed to stdout, with normal exit status.
  | Result String
  -- | An error messge to be printe to stderr, with failing exit status.
  | Error  String

-- | Iterate over each line in stdin
forLines :: Handle -> (String -> IO ()) -> IO ()
forLines h f = do
  encoded <- hGetContents h
  for_ (lines encoded) f

-- | Determine which command to run based on argv.
dispatch :: Env -> [String] -> Cmd
dispatch env = impl
  where
    impl ["adjacent", e, d]   = handleAdjacent e d
    impl ["from", bucket]     = Stream $ (lift $ readBucket env bucket) >>= each
    impl ["reachable", e, d]  = handleReachable e d
    impl ("reachable_from" : rest) = handleReachableFrom rest
    impl ["union", rhs]       = Stream $ handleUnion rhs
    impl ("filter_state" : s) = stateFilter s
    impl ["subtasks", node]   = Stream $ getSubtasks env (Id node)
    impl ["is_leaf"]          = EdgeFilter Dependencies Outgoing (invert hasAdjacent)
    impl ["is_next"]          = EdgeFilter Dependencies Outgoing isNext
    impl ["is_orphan"]        = EdgeFilter Dependencies All      (invert hasAdjacent)
    impl ["is_project"]       = Filter $ has (Datum "subtasks")
    impl ["is_root"]          = EdgeFilter Dependencies Incoming (invert hasAdjacent)
    impl ["is_unassigned"]    = EdgeFilter Contexts     Incoming (invert hasAdjacent)
    impl ["is_nonterminal"]   = EdgeFilter Dependencies All      hasAdjacent
    impl ("dot" : rest)       = Eff $ printDot rest
    impl ["summary"]          = Eff $ printSummary env Nothing
    impl ["summary", "-d", d] = Eff $ printSummary env $ Just d
    -- scheduler commands
    impl ("is_complete" : w)  = withWindow env w $ isComplete env
    impl ("is_incomplete": w) = withWindow env w isIncomplete
    impl ("is_scheduled": w)  = Filter $ has (Datum "schedule")
    impl ("is_unscheduled" : w) = Filter $ invert' $ has (Datum "schedule")
    impl ["in_progress"]      = Filter $ inProgress
    impl ("completed" : w)    = withWindow env w $ completed env
    impl ["classify"]         = undefined -- XXX
    impl ("preview" : m : w)  = withWindow env w $ \w -> Eff $ forLines stdin (S.preview m w)
    impl ["validate"]         = Eff $ forLines stdin S.validateDS
    impl ("agenda" : sel)     = Eff $ agenda env $ Set.fromList $ Id <$> sel

    -- testing
    impl ["vtest"]            = Eff vtyMain

    -- default
    impl bad                  = Error $ "not implemented: " ++ unwords bad

    handleAdjacent e d = case parseEdgeSet e of
      Nothing -> Error $ "Invalid edge set: " ++ e
      Just e -> case parseDirection d of
        Nothing -> Error $ "Invalid direction: " ++ d
        Just d -> Stream $ adjacent env e d

    handleReachable e d = case parseEdgeSet e of
      Nothing -> Error $ "Invalid edge set: " ++ e
      Just e -> case parseDirection d of
        Nothing -> Error $ "Invalid direction: " ++ d
        Just d -> Stream $ do
          g <- lift $ readGraph env e d
          readIds stdin >-> reachable g

    handleReachableFrom (e : d : nodes) = case parseEdgeSet e of
      Nothing -> Error $ "Invalid edge set: " ++ e
      Just e -> case parseDirection d of
        Nothing -> Error $ "Invalid direction: " ++ d
        Just d -> EdgeFilter e d $ reachableFrom $ Set.fromList $ Id <$> nodes
    handleReachableFrom bad = Error $ "Invalid Arguments: " ++ show bad

    stateFilter states = case validateStates states of
      Left  err    -> Error err
      Right states -> Filter $ filterState (Set.fromList states)

    validateStates states = validate states parseState ("Invalid state: " ++)

    handleUnion rhs = do
      rhs <- lift $ openFile rhs ReadMode
      Brainbox.Graph.union stdin rhs

    printDot selection =
      do
        rendered <- output env.show_virtual
        TIO.putStrLn $ printIt $ digraph' $ rendered
      where
        selection' = Set.fromList $ Id <$> selection
        output True  = render @INode env selection'
        output False = render @Id    env selection'

    inProgress :: Predicate Id
    inProgress env id = do
      sched <- taskSchedule env id
      case sched of
        Nothing -> return True
        Just sched  -> return $ DS.within sched env.now

    isComplete :: Env -> I.TimePeriod -> Cmd
    isComplete env window = Filter $ \env id -> do
      sched <- taskSchedule env id
      hist  <- taskHistory  env id
      case sched of
        Nothing -> return $ not $ null hist
        Just sched -> return $ DS.isComplete sched hist window

    isIncomplete :: I.TimePeriod -> Cmd
    isIncomplete window = Filter $ \env id -> do
      sched <- taskSchedule env id
      hist  <- taskHistory  env id
      case sched of
        Nothing -> return $ null hist
        Just sched -> return $ not $ DS.isComplete sched hist window

    completed :: Env -> I.TimePeriod -> Cmd
    completed env window = Eff $ runEffect $ for (readIds stdin) $ \id -> do
      sched <- lift $ taskSchedule env id
      hist  <- lift $ taskHistory  env id
      case sched of
        Nothing -> pure ()
        Just sched -> lift $ putStrLn $ S.completionGraph sched hist window

-- | Abstract common code for streams of nodes.
runStream :: Producer Id IO () -> IO ()
runStream stream = runEffect $ for stream (lift . printId)

-- | Abstract common code for running node filters, which also process
-- data from stdin.
runFilter :: Env -> Predicate Id -> IO ()
runFilter env predicate = runStream (readIds stdin >-> filterNodes env predicate)

-- | Run filters that require access to the graph structure.
runEdgeFilter :: Env -> EdgeSet -> Direction -> EdgePredicate Id -> IO ()
runEdgeFilter env edges direction predicate = do
  edges <- readGraph env edges direction
  runFilter env (predicate edges)

vtyMain :: IO ()
vtyMain = do
  vty <- mkVty Vty.defaultConfig
  let line0 = Vty.string (Vty.defAttr `Vty.withForeColor` Vty.green) "first line"
      line1 = Vty.string (Vty.defAttr `Vty.withBackColor` Vty.blue) "second line"
      img   = line0 Vty.<-> line1
      pic   = Vty.picForImage img
  Vty.update vty pic
  e <- Vty.nextEvent vty
  Vty.shutdown vty
  print ("Last event was: " ++ show e)

-- | Main entry point.
main :: IO ()
main = do
  env  <- getEnvState
  args <- getArgs
  case dispatch env args of
    Filter f -> runFilter env f
    EdgeFilter e d p -> runEdgeFilter env e d p
    Stream s -> runStream s
    Eff    e -> e
    Result s -> putStrLn  s
    Error  e -> error     e
