{-# LANGUAGE TupleSections #-}
{-# LANGUAGE CPP #-}
{-# OPTIONS_HADDOCK hide #-}
module Text.HTML.Scalpel.Internal.Serial (
    SerialScraper
,   inSerial
,   stepBack
,   stepNext
,   seekBack
,   seekNext
,   untilBack
,   untilNext
) where

import Text.HTML.Scalpel.Internal.Scrape
import Text.HTML.Scalpel.Internal.Select

import Control.Applicative
import Control.Monad
import Data.List.PointedList (PointedList)

import qualified Control.Monad.Fail as Fail
import qualified Data.List.PointedList as PointedList
import qualified Data.Tree as Tree
import qualified Text.StringLike as TagSoup


-- | Serial scrapers operate on a zipper of tag specs that correspond to the
-- root nodes / siblings in a document.
--
-- Access to the zipper is always performed in a move-then-read manner. For this
-- reason it is valid for the current focus of the zipper to be just off either
-- end of list such that moving forward or backward would result in reading the
-- first or last node.
--
-- These valid focuses are expressed as Nothing values at either end of the
-- zipper since they are valid positions for the focus to pass over, but not
-- valid positions to read.
type SpecZipper str = PointedList (Maybe (TagSpec str))

-- | A 'SerialScraper' allows for the application of 'Scraper's on a sequence of
-- sibling nodes. This allows for use cases like targeting the sibling of a
-- node, or extracting a sequence of sibling nodes (e.g. paragraphs (\<p\>)
-- under a header (\<h2\>)).
--
-- Conceptually serial scrapers operate on a sequence of tags that correspond to
-- the immediate children of the currently focused node. For example, given the
-- following HTML:
--
-- @
--  \<article\>
--    \<h1\>title\</h1\>
--    \<h2\>Section 1\</h2\>
--    \<p\>Paragraph 1.1\</p\>
--    \<p\>Paragraph 1.2\</p\>
--    \<h2\>Section 2\</h2\>
--    \<p\>Paragraph 2.1\</p\>
--    \<p\>Paragraph 2.2\</p\>
--  \</article\>
-- @
--
-- A serial scraper that visits the header and paragraph nodes can be executed
-- with the following:
--
-- @
-- 'chroot' "article" $ 'inSerial' $ do ...
-- @
--
-- Each 'SerialScraper' primitive follows the pattern of first moving the focus
-- backward or forward and then extracting content from the new focus.
-- Attempting to extract content from beyond the end of the sequence causes the
-- scraper to fail.
--
-- To complete the above example, the article's structure and content can be
-- extracted with the following code:
--
-- @
-- 'chroot' "article" $ 'inSerial' $ do
--     title <- 'seekNext' $ 'text' "h1"
--     sections <- many $ do
--        section <- 'seekNext' $ text "h2"
--        ps <- 'untilNext' ('matches' "h2") (many $ 'seekNext' $ 'text' "p")
--        return (section, ps)
--     return (title, sections)
-- @
--
-- Which will evaluate to:
--
-- @
--  ("title", [
--    ("Section 1", ["Paragraph 1.1", "Paragraph 1.2"]),
--    ("Section 2", ["Paragraph 2.1", "Paragraph 2.2"]),
--  ])
-- @
newtype SerialScraper str a =
    MkSerialScraper (SpecZipper str -> Maybe (a, SpecZipper str))

instance Functor (SerialScraper str) where
    fmap f (MkSerialScraper a) = MkSerialScraper applied
      where applied zipper
                | Just (aVal, zipper') <- a zipper = Just (f aVal, zipper')
                | otherwise                        = Nothing

instance Applicative (SerialScraper str) where
    pure a = MkSerialScraper $ \zipper -> Just (a, zipper)
    (MkSerialScraper f) <*> (MkSerialScraper a) = MkSerialScraper applied
        where
          applied zipper = do
              (f', zipper')  <- f zipper
              (a', zipper'') <- a zipper'
              return (f' a', zipper'')

instance Alternative (SerialScraper str) where
    empty = MkSerialScraper $ const Nothing
    (MkSerialScraper a) <|> (MkSerialScraper b) = MkSerialScraper choice
        where choice zipper | (Just aVal) <- a zipper = Just aVal
                            | otherwise               = b zipper

instance Monad (SerialScraper str) where
#if !MIN_VERSION_base(4,13,0)
    fail = Fail.fail
#endif
    return = pure
    (MkSerialScraper a) >>= f = MkSerialScraper combined
        where
          combined zipper = do
              (aVal, zipper') <- a zipper
              let (MkSerialScraper b) = f aVal
              b zipper'

instance MonadPlus (SerialScraper str) where
    mzero = empty
    mplus = (<|>)

instance Fail.MonadFail (SerialScraper str) where
    fail _ = mzero

-- | Executes a 'SerialScraper' in the context of a 'Scraper'. The immediate
-- children of the currently focused node are visited serially.
inSerial :: TagSoup.StringLike str => SerialScraper str a -> Scraper str a
inSerial (MkSerialScraper serialScraper) = MkScraper scraper
  where
    scraper spec@(vec, root : _, ctx)
      | ctxInChroot ctx = fst <$> serialScraper
                                  (toZipper (vec, Tree.subForest root, ctx))
      | otherwise       = fst <$> serialScraper (toZipper spec)
    scraper _           = Nothing

    -- Create a zipper from the current tag spec by generating a new tag spec
    -- that just contains each root node in the forest.
    toZipper (vector, forest, context) =
        zipperFromList $ map ((vector, , context) . return) forest

-- | Creates a SpecZipper from a list of tag specs. This requires bookending the
-- zipper with Nothing values to denote valid focuses that are just off either
-- end of the list.
zipperFromList :: TagSoup.StringLike str => [TagSpec str] -> SpecZipper str
zipperFromList = PointedList.insertLeft Nothing
               . foldr (PointedList.insertLeft . Just)
                       (PointedList.singleton Nothing)

stepWith :: TagSoup.StringLike str
         => (SpecZipper str -> Maybe (SpecZipper str))
         -> Scraper str b
         -> SerialScraper str b
stepWith moveList (MkScraper scraper) = MkSerialScraper $ \zipper -> do
    zipper' <- moveList zipper
    focus <- PointedList._focus zipper'
    value <- scraper focus
    return (value, zipper')

-- | Move the cursor back one node and execute the given scraper on the new
-- focused node.
stepBack :: TagSoup.StringLike str => Scraper str a -> SerialScraper str a
stepBack = stepWith PointedList.previous

-- | Move the cursor forward one node and execute the given scraper on the new
-- focused node.
stepNext :: TagSoup.StringLike str => Scraper str a -> SerialScraper str a
stepNext = stepWith PointedList.next

seekWith :: TagSoup.StringLike str
         => (SpecZipper str -> Maybe (SpecZipper str))
         -> Scraper str b
         -> SerialScraper str b
seekWith moveList (MkScraper scraper) = MkSerialScraper go
    where
      go zipper = do
        zipper' <- moveList zipper
        runScraper zipper' <|> go zipper'
      runScraper zipper = do
        focus <- PointedList._focus zipper
        value <- scraper focus
        return (value, zipper)

-- | Move the cursor backward until the given scraper is successfully able to
-- execute on the focused node. If the scraper is never successful then the
-- serial scraper will fail.
seekBack :: TagSoup.StringLike str => Scraper str a -> SerialScraper str a
seekBack = seekWith PointedList.previous

-- | Move the cursor forward until the given scraper is successfully able to
-- execute on the focused node. If the scraper is never successful then the
-- serial scraper will fail.
seekNext :: TagSoup.StringLike str => Scraper str a -> SerialScraper str a
seekNext = seekWith PointedList.next

untilWith :: TagSoup.StringLike str
         => (SpecZipper str -> Maybe (SpecZipper str))
         -> (Maybe (TagSpec str) -> SpecZipper str -> SpecZipper str)
         -> Scraper str a
         -> SerialScraper str b
         -> SerialScraper str b
untilWith moveList appendNode
          (MkScraper untilScraper) (MkSerialScraper scraper) =
  MkSerialScraper $ \zipper -> do
      let (innerZipper, zipper') = split zipper
      (value, _)  <- scraper $ appendNode Nothing innerZipper
      return (value, zipper')
  where
    split zipper
        | Just zipper' <- moveList zipper
        , Just spec    <- PointedList._focus zipper'
        , Nothing <- untilScraper spec =
            let (specs, zipper'') = split zipper'
            in  (appendNode (Just spec) specs, zipper'')
        | otherwise                   = (PointedList.singleton Nothing, zipper)

-- | Create a new serial context by moving the focus backward and collecting
-- nodes until the scraper matches the focused node. The serial scraper is then
-- executed on the collected nodes.
untilBack :: TagSoup.StringLike str
          => Scraper str a -> SerialScraper str b -> SerialScraper str b
untilBack = untilWith PointedList.previous PointedList.insertRight

-- | Create a new serial context by moving the focus forward and collecting
-- nodes until the scraper matches the focused node. The serial scraper is then
-- executed on the collected nodes.
--
-- The provided serial scraper is unable to see nodes outside the new restricted
-- context.
untilNext :: TagSoup.StringLike str
          => Scraper str a -> SerialScraper str b -> SerialScraper str b
untilNext = untilWith PointedList.next PointedList.insertLeft
