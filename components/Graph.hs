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
module Brainbox.Graph where

-- local imports
import Util

-- 3rd party
import Pipes
import qualified Pipes.Prelude as P
import Data.List.Split
import Data.String.Utils
import Data.Foldable.Extra
import Data.List.Extra (upper)
import Data.GraphViz.Types.Monadic
import Data.GraphViz.Attributes
import qualified Data.GraphViz.Attributes.Complete as C
import qualified Data.GraphViz.Attributes.Colors as Colors
import Data.GraphViz.Parsing
import Data.GraphViz.Printing
import qualified Data.Text.Lazy as T
import qualified Data.Text.Lazy.IO as TIO

-- standard lib imports
import Control.Monad
import Control.Exception
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
  debug_edges   :: Bool
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

class IdOf idT where
  idOf :: idT -> String

instance IdOf Id where
  idOf (Id x) = x

instance IdOf INode where
  idOf (Node x) = x
  idOf (Start x) = x ++ "::start"

getId :: INode -> String
getId (Start id) = id
getId (Node  id) = id

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

idToINode :: Edge Id -> Edge INode
idToINode (Id u, Id v, k) = (Node u, Node v, k)

pdot :: ParseDot a => String -> a
pdot s = parseIt' $ T.pack $ quoted
  where
    -- hack alert!  hex colors fail to parse parse correctly when
    -- unquoted. graphviz package might be more trouble than it's
    -- worth for us.
    quoted = "\"" ++ s ++ "\""

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
    ids <- listDirectory path
    return $ Id <$> ids

-- | Try to Read the Datum from the given node id
readDatum :: Env -> Datum -> Id -> Producer String IO ()
readDatum env (Datum d) (Id i) =
  let path = env.node_dir ++ "/" ++ i ++ "/" ++ d
  in do
    handle <- lift $ openFile path ReadMode
    P.fromHandle handle

withFirstLine :: (String -> Maybe a) -> Datum -> Env -> Id -> IO (Maybe a)
withFirstLine parser datum env id = do
  line <- P.head $ readDatum env datum id
  return $ Control.Monad.join $ parser <$> line

taskContents :: Env -> Id -> Producer String IO ()
taskContents env = readDatum env (Datum "contents")

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

-- | Abstract over the edge type.
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
-- Since the output cannot contain start nodes, these are merged.
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
edgeTouches
  :: (Eq idT, Ord idT)
  => Edge idT
  -> Set idT
  -> Bool
edgeTouches (u, v, _) nodes = (Set.member u nodes) || (Set.member v nodes)

-- | True if the given edge is completely within the given nodes.
edgeContained
  :: (Eq idT, Ord idT)
  => Edge idT
  -> Set idT
  -> Bool
edgeContained (u, v, _) nodes = (Set.member u nodes) && (Set.member v nodes)

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
    go :: Graph INode -> Pipe Id Id IO ()
    go graph = do
      id@(Id node) <- await
      yield id
      case Map.lookup (Node node) graph of
        Nothing        -> go graph
        Just neighbors -> do
          each neighbors >-> P.map (Id . idOf)
          go graph

-- | Helper to invert predicates, which is verbose because of monads.
invert :: EdgePredicate idT -> EdgePredicate idT
invert pred graph env id = do
  res <- pred graph env id
  return $ not res

type BinPred idT =
     Predicate idT
  -> Predicate idT
  -> Predicate idT

-- | Helper to take the logical conjunction of two predicates
binop :: (Bool -> Bool -> Bool) -> BinPred idT
binop op a b env id = do
  a <- a env id
  b <- b env id
  return $ op a b

-- | Take the logical and of two predicates.
and :: BinPred idT
and = binop (&&)

-- | Take the logical or of two predicates.
or :: BinPred idT
or = binop (||)

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

reachabilitySet :: Graph Id -> Set Id -> Set Id
reachabilitySet g nodes = Set.unions $ Set.map (reachable g) nodes
  where
    reachable :: Graph Id -> Id -> Set Id
    reachable g n = case Map.lookup n g of
      Nothing -> Set.empty
      Just neighbors -> Set.unions $ Set.map (reachable g) neighbors

reachableFrom :: Set Id -> EdgePredicate Id
reachableFrom nodes g _ id =
  let reachable = reachabilitySet g nodes
  in return $ Set.member id reachable

reachable :: Graph Id -> Pipe Id Id IO ()
reachable g = do
  nodes <- lift $ P.fold (flip Set.insert) Set.empty id $ readIds stdin
  each $ reachabilitySet g nodes

danglingContexts :: Env -> Producer Id IO ()
danglingContexts env = do
  existing <- lift $ P.fold (flip Set.insert) Set.empty id $ nodes env
  for (edgeList @(Edge Id) env Contexts) $ \(u, v, _) -> do
    case (Set.member u existing, Set.member v existing) of
      (True, False) -> yield u
      (False, True) -> yield v
      _             -> pure ()

-- this is some real bs right here.
-- the more I use it, the less I like this graphviz API.
parseColor :: String -> Colors.Color
parseColor s = pdot $ '#' : s
class HexColor a where
  hex :: (a -> Attribute) -> String -> Attribute
instance HexColor Colors.ColorList where
  hex attr s = attr $ [C.toWC $ parseColor s]
instance HexColor Colors.Color where
  hex attr s = attr $ parseColor s

-- | Dotfile export
render :: Env -> Set INode -> IO (Dot String)
render env selection =
  do
    (projects, nodes, labels, states) <- P.foldM
      collectNodes
      (return (Set.empty, selection, Map.empty, Map.empty))
      (return)
      (readIds stdin)

    buckets  <- listDirectory env.bucket_dir >>= mapM rb
    source   <- readBucket env "source"
    target   <- readBucket env "target"
    deps     <- P.toListM $ edgeList @(Edge INode) env Dependencies
    contexts <- P.toListM $ edgeList @(Edge INode) env Contexts

    return $ do
      graphAttrs [
        C.RankDir env.rankdir,
        C.FontName $ T.pack env.font,
        C.BgColor $ [C.toWC env.background]]

      for_ buckets $ \(bucket, contents) -> do
        node bucket [shape House, style filled, bgColor Gray95]
        for_ contents $ \c -> do
          edge bucket c [style dashed, color Gray]

      for_ source $ \(Id u) -> do
        for_ target $ \(Id v) -> do
          edge u v [style dashed, color Gray]

      for_ nodes $ doNode projects labels states
      when env.show_deps     $ for_ deps     $ doEdge Red
      when env.show_contexts $ for_ contexts $ doEdge Green
  where
    rb :: String -> IO (String, [String])
    rb bucket = do
      contents <- readBucket env bucket
      return (bucket, idOf <$> contents)

    doNode projects labels states n = node (idOf n)
      $ style filled
      : labelOf n
      : shapeOf n
      : penWidth 2
      : colorOf n
      where
        labelOf (Start id) = toLabel $ (fromMaybe id $ Map.lookup id labels) ++ "\nΦ"
        labelOf (Node id)  = toLabel $ fromMaybe id $ Map.lookup id labels

        shapeOf (Start _) = shape C.CDS
        shapeOf (Node id)  = case Set.member id projects of
          True  -> shape Folder
          False -> shape BoxShape

        colorOf node = case Map.lookup (getId node) states of
          Just New     -> [      fillColor DeepPink,      color DeepPink,       fontColor Black]
          Just Todo    -> [      fillColor Gray95,        color Gray95,         fontColor Black]
          Just Done    -> [hex C.FillColor "ccffcc",hex C.Color "ccffcc", hex C.FontColor "99cc99"]
          Just Dropped -> [hex C.FillColor "ffdddd",hex C.Color "ffdddd", hex C.FontColor "ff9999"]
          Just Wait    -> [      fillColor Red,           color Red,            fontColor Black]
          Just Someday -> [hex C.FillColor "ddaaff",hex C.Color "ddaaff",       fontColor Black]
          Just Info    -> [      fillColor Gold,          color Gold,           fontColor Black]
          Just Focus   -> [      fillColor Green,         color Green,          fontColor Black]
          Just Context -> [hex C.FillColor "aaffdd",hex C.Color "aaffdd",       fontColor Black]
          _            -> [      fillColor Gray95,        color Gray95,         fontColor Gray50]

    empty :: Arrow
    empty = C.AType [(C.openMod, C.Normal)]

    doEdge :: X11Color -> Edge INode -> Dot String
    doEdge c (u, v, k) = edge (idOf u) (idOf v) $ styleEdge c k

    styleEdge :: X11Color -> EdgeType -> Attributes
    styleEdge c Explicit = [style solid,  color c]
    styleEdge c Subtask  = [style dashed, color c]
    styleEdge c Leaf     = [style dashed, color c, arrowTo empty]
    styleEdge c Sibling  = [style dashed, color c, arrowTo oDot]
    styleEdge c Suspect  = [style dashed, color c, arrowTo oDiamond]

    collectNodes :: (Set String, Set INode, Map String String, Map String State) -> Id -> IO (Set String, Set INode, Map String String, Map String State)
    collectNodes (projects, nodes, labels, states) i@(Id id) = do
      has_subtasks <- has (Datum "subtasks") env i
      label <- taskGloss env i
      state <- taskState env i
      let labels' = Map.insert id (fromMaybe "[no contents]" label) labels
      let states' = fromMaybe states $ (\x -> Map.insert id x states) <$> state
      return $ if has_subtasks
        then ( Set.insert id projects
             , Set.insert (Node id) $ Set.insert (Start id) nodes
             , labels'
             , states')
        else ( projects
             , Set.insert (Node id) nodes
             , labels'
             , states')

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
    impl _                    = Error "not implemented"

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

    printDot nodes = do
      output <- render env $ Set.fromList $ Node <$> nodes
      TIO.putStrLn $ printIt $ digraph' output

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
