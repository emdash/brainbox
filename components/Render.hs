{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE ExtendedDefaultRules #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE AllowAmbiguousTypes #-}
{-# LANGUAGE TypeApplications #-}

-- | Routines for "drawing" to the console via implicit functions.
--
-- The goal isn't efficiency, interaction, or "full screen"
-- rendering. The goal is "intermediate" terminal semigraphics / box
-- drawing easily compatible with the FZF preview window, or printing
-- direct to console.

module Render (
  LabledRect,
  ImplicitFn,
  Layer,
  Image,
  translate,
  transform,
  compose,
  combine,
  composite,
  scene,
  fill,
  overlay,
  splitH,
  splitH',
  splitV,
  splitV',
  vertically,
  rect,
  roundBox,
  wrap,
  text,
  renderRow,
  render,
  renderCondensed,
  putH
) where

import Debug.Trace

-- | Stdlib imports
import Data.Foldable
import Data.List
import Data.Maybe
import System.IO


-- | Local imports
import Util

-- Types ----------------------------------------------------------------------

-- | Type of discrete implicit functions in two dimensions.
type ImplicitFn a = (Int, Int) -> a

-- | A layer in an image.
type Layer a = ImplicitFn (Maybe a)

-- | A concrete image.
type Image = ImplicitFn Char

-- Combinators ----------------------------------------------------------------

-- | Modify an image by filtering the output.
filter :: (a -> b) -> ImplicitFn a -> ImplicitFn b
filter f g = f . g

-- | Modify an image by transforming the input.
transform :: ((Int, Int) -> (Int, Int)) -> ImplicitFn a -> ImplicitFn a
transform f g = g . f

-- | Translate an implicit function by the given amount.
translate :: Int -> Int -> ImplicitFn a -> ImplicitFn a
translate oy ox = transform $ \(y, x) -> (y - oy, x - ox)

-- | Combine two implicit functions using the given merge function.
compose :: (a -> b -> c) -> ImplicitFn a -> ImplicitFn b -> ImplicitFn c
compose merge left right pt = merge (left pt) (right pt)

-- | Combine two image layers, producing a layer. Right-most is top-most.
combine :: Layer a -> Layer a -> Layer a
combine bottom top = compose takeLast bottom top

-- | Combine a partial foreground layer with a complete background image.
overlay :: Image -> Layer Char -> Image
overlay background foreground = compose fromMaybe background foreground

-- | Combine multiple layers, producing a layer. Right occludes left.
composite :: [Layer a] -> Layer a
composite []        = const Nothing
composite [x]       = x
composite (x : xs) = foldl combine x xs

-- | Combine foreground layers with a background layer to produce a complete image.
scene :: Image -> [Layer Char] -> Image
scene bg fg = overlay bg $ composite fg

-- | Divide an image horizontally between two functions.
splitH :: Int -> Maybe a -> ImplicitFn a -> ImplicitFn a -> ImplicitFn a
splitH atCol sep left right = splitH' atCol sep left $ translate 0 offset $ right
  where
    offset = atCol + (fromMaybe 0 $ const 1 <$> sep)

-- | Like splitH, but the right view is not translated.
splitH' :: Int -> Maybe a -> ImplicitFn a -> ImplicitFn a -> ImplicitFn a
splitH' atCol Nothing    left right pt@(y, x) | x < atCol = left pt
splitH' atCol Nothing    left right pt@(y, x) = right pt
splitH' atCol (Just sep) left right pt@(y, x) = case compare x atCol of
  LT -> left pt
  EQ -> sep
  GT -> right pt

-- | Divide the image vertically between two functions.
splitV :: Int -> Maybe a -> ImplicitFn a -> ImplicitFn a -> ImplicitFn a
splitV atRow sep top bottom = splitV' atRow sep top $ translate offset 0 $ bottom
  where
    offset = atRow + (fromMaybe 0 $ const 1 <$> sep)

-- | Like splitV, but the bottom view is not translated.
splitV' :: Int -> Maybe a -> ImplicitFn a -> ImplicitFn a -> ImplicitFn a
splitV' atRow Nothing    top bottom pt@(y, x) | x < atRow = top pt
splitV' atRow Nothing    top bottom pt@(y, x) = bottom pt
splitV' atRow (Just sep) top bottom pt@(y, x) = case compare x atRow of
  LT -> top pt
  EQ -> sep
  GT -> bottom pt

vertically :: Int -> [Layer a] -> Layer a
vertically spacing layers = composite $ adjust <$> zip [0..] layers
  where
    adjust (y, l) = translate (y * spacing) 0 l

-- Primitives -----------------------------------------------------------------
-- TBD: other primitives.

-- | The same value at every point
fill :: a -> ImplicitFn a
fill = const

-- | A labeled box to be printed on the screen in ANSI glory.
type LabledRect = (String, Int, Int, Int, Int)

-- | Construct a single labeled rectangle.
rect :: String -> Int -> Int -> Int -> Int -> LabledRect
rect label x y w h = (label, x, y, w, h)

-- | The result of a testing a value for membership in an ordered set.
--
-- A value is either inside, outside, or on a boundary. Here we
-- distinguish between the lower and upper boundary, to make it easier
-- to identify the corners of a rectangle.
data Sample a  = LowerBound | Inside a | UpperBound | Outside

-- | Sample a value over a 1D range and return the result.
--
-- You can think of this like a generalization of `between` in the
-- Util module, but with a richer result type.
--
-- Not quite signed distance fields, but it's a similar idea.
sample :: Int -> Int -> Int -> Sample Int
sample l x u = case compare x l of
  LT -> Outside
  EQ -> LowerBound
  GT -> case compare x u of
    LT -> Inside $ x - l - 1
    EQ -> UpperBound
    GT -> Outside

-- | An implicit function to render a labeled box with round corners.
roundBox :: Char -> LabledRect -> Layer Char
roundBox bg (l, rx, ry, w, h) (y, x) =
  case (sample 0 (x - rx) w, sample 0 (y - ry) h) of
    (LowerBound, LowerBound)  -> Just '\x256D' -- top left
    (UpperBound, LowerBound)  -> Just '\x256E' -- top right
    (LowerBound, UpperBound)  -> Just '\x2570' -- bottom left
    (UpperBound, UpperBound)  -> Just '\x256F' -- bottom right
    (LowerBound, Inside _)    -> Just '\x2502' -- left side
    (UpperBound, Inside _)    -> Just '\x2502' -- right side
    (Inside _,   LowerBound)  -> Just '\x2500' -- top side
    (Inside _,   UpperBound)  -> Just '\x2500' -- bottom side
    (Inside x,   Inside y)    -> combine (fill (Just bg)) (wrap (w - 1) l) (y, x)
    _                         -> Nothing

-- | Render a string wrapped to the given width.
--
-- This is naive character-based wrapping, We don't try to do
-- sophisticated word-breaks.
wrap :: Int -> String -> Layer Char
wrap w s (y, x) = s !? (x + (y * w))

-- | Render a string on a single line.
text :: String -> Layer Char
text s (y, x) | y == 0 = s !? x
text _ _               = Nothing

-- Rendering ------------------------------------------------------------------

-- | Render an implicit function to a row of cells.
renderRow :: Int -> ImplicitFn a -> Int -> [a]
renderRow w f y = f <$> (y,) <$> [0..(w - 1)]

-- | Render implict fn to a list of rows.
render :: Int -> Int -> ImplicitFn a -> [[a]]
render w h f = renderRow w f <$> [0..(h - 1)]

-- | Render with condensation
--
-- This will skip consecutive rows where the foreground layer is the
-- same, producing a shorter image.
--
-- This is used to compress the agenda day view.
renderCondensed :: Int -> Int -> Image -> Layer Char -> [String]
renderCondensed w h background foreground =
  mapMaybe
    condense
    $ applyPairwise (renderRow w foreground) [] [0..(h - 1)]
  where
    condense (y, cur, prev) =
      if cur == prev
        then Nothing
        else Just $ uncurry fromMaybe <$> zip (renderRow w background y) cur

putH :: Handle -> Int -> Int -> Image -> IO ()
putH hdl w h image = for_ (render (traceShowId w) h image) $ hPutStrLn hdl
