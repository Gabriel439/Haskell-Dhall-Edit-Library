{-# LANGUAGE ApplicativeDo             #-}
{-# LANGUAGE ExistentialQuantification #-}
{-# LANGUAGE OverloadedStrings         #-}
{-# LANGUAGE RecordWildCards           #-}

module Dhall.Edit where

import Brick
import Brick.Focus (FocusRing)
import Brick.Types (BrickEvent(..))
import Brick.Widgets.Edit (Editor)
import Control.Applicative (liftA2)
import Control.Monad (join)
import Control.Monad.Trans.State (State)
import Data.Monoid (Monoid(..), Sum(..), (<>))
import Data.Text (Text)
import Dhall.Core (Expr(..))
import Dhall.TypeCheck (X)
import Graphics.Vty.Input.Events (Event(..), Key(..))
import Numeric.Natural (Natural)

import qualified Brick
import qualified Brick.Focus
import qualified Brick.Widgets.Edit
import qualified Control.Monad.Trans.State
import qualified Data.Map
import qualified Data.Text
import qualified Data.Text.Lazy
import qualified Data.Text.Lazy.Builder
import qualified Data.Text.Zipper
import qualified Lens.Micro
import qualified Text.Read

-- TODO: Don't use 99 for Viewport

ui :: Widget ()
ui = str "Hello, world!"

data Status = Status {}

initialStatus :: Status
initialStatus = Status {}

data Fold a =
    forall s . Fold (Natural -> s -> Event -> EventM Natural s) s (FocusRing Natural-> s -> a)

instance Functor Fold where
    fmap k (Fold step begin done) = Fold step begin done'
      where
        done' b s = k (done b s)

instance Applicative Fold where
    pure r = Fold (\_ s _ -> pure s) () (\_ _ -> r)

    Fold stepL beginL doneL <*> Fold stepR beginR doneR = Fold step begin done
      where
        step n (sL, sR) e = do
            sL' <- stepL n sL e
            sR' <- stepR n sR e
            return (sL', sR')

        begin = (beginL, beginR)

        done b (sL, sR) = doneL b sL (doneR b sR)

instance Monoid a => Monoid (Fold a) where
    mempty = pure mempty

    mappend = liftA2 mappend

newtype W = W { getW :: Widget Natural }

instance Monoid W where
    mempty = W emptyWidget

    mappend (W l) (W r) = W (l <=> r)

newtype UI a = UI
    { getUI :: (Sum Natural, State Natural (Fold (W, Maybe a)))
    }

instance Functor UI where
    fmap k (UI x) = UI (fmap (fmap (fmap (fmap (fmap k)))) x)

instance Applicative UI where
    pure x = UI (pure (pure (pure (pure (pure x)))))

    UI l <*> UI r = UI (liftA2 (liftA2 (liftA2 (liftA2 (<*>)))) l r)

instance Monoid a => Monoid (UI a) where
    mempty = pure mempty

    mappend = liftA2 mappend

modifyWidget :: (Widget Natural -> Widget Natural) -> UI a -> UI a
modifyWidget f (UI x) = UI (fmap (fmap (fmap adapt)) x)
  where
    adapt (W widget, y) = (W (f widget), y)

absorb :: UI (Maybe a) -> UI a
absorb (UI ui) = UI (fmap (fmap (fmap (fmap join))) ui)

editText :: Text -> UI Text
editText startingText = UI (Sum 1, do
    n <- Control.Monad.Trans.State.get
    Control.Monad.Trans.State.put (n + 1)

    let begin :: Editor Text Natural
        begin =
            Brick.Widgets.Edit.editorText
                    n
                    (Brick.str . Data.Text.unpack . Data.Text.intercalate "\n")
                    (Just 1)
                    startingText

        step
            :: Natural
            -> Editor Text Natural
            -> Event
            -> EventM Natural (Editor Text Natural)
        step n' editor event =
            if n == n'
            then Brick.Widgets.Edit.handleEditorEvent event editor
            else return editor

        done :: FocusRing Natural -> Editor Text Natural -> (W, Maybe Text)
        done r editor =
            ( W (Brick.Focus.withFocusRing r (Brick.Widgets.Edit.renderEditor) editor)
            , Just (Data.Text.intercalate "\n" (Brick.Widgets.Edit.getEditContents editor))
            )

    return (Fold step begin done) )

editBool :: Bool -> UI Bool
editBool startingBool = UI (Sum 1, do
    n <- Control.Monad.Trans.State.get
    Control.Monad.Trans.State.put (n + 1)

    let toText :: Bool -> Text
        toText False = "☐"
        toText True  = "☑"

    let begin :: (Bool, Editor Text Natural)
        begin =
            (   startingBool
            ,   Brick.Widgets.Edit.editorText
                    n
                    (Brick.str . Data.Text.unpack . Data.Text.intercalate "\n")
                    (Just 1)
                    (toText startingBool)
            )

        step
            :: Natural
            -> (Bool, Editor Text Natural)
            -> Event
            -> EventM Natural (Bool, Editor Text Natural)
        step n' (currentValue, editor) event =
            if n == n'
            then case event of
                EvKey (KChar ' ') [] -> return toggle
                _                    -> return nothing
            else return nothing
          where
            toggle = (currentValue', editor')
              where
                currentValue' = not currentValue

                zipper =
                    Data.Text.Zipper.textZipper [toText currentValue'] (Just 1)

                editor' =
                    Lens.Micro.set Brick.Widgets.Edit.editContentsL zipper editor

            nothing = (currentValue, editor)

        done
            :: FocusRing Natural
            -> (Bool, Editor Text Natural)
            -> (W, Maybe Bool)
        done r (currentValue, editor) =
            ( W (Brick.Focus.withFocusRing r (Brick.Widgets.Edit.renderEditor) editor)
            , Just currentValue
            )

    return (Fold step begin done) )


dhallEdit :: Expr X X -> UI (Expr X X)
dhallEdit (TextLit builder) = do
    let lazyText   = Data.Text.Lazy.Builder.toLazyText builder
    let strictText = Data.Text.Lazy.toStrict lazyText
    strictText' <- editText strictText
    return (
        let lazyText' = Data.Text.Lazy.fromStrict strictText'
            builder'  = Data.Text.Lazy.Builder.fromLazyText lazyText'
        in  TextLit builder' )
dhallEdit (BoolLit bool) = fmap BoolLit (editBool bool)
dhallEdit (DoubleLit n) = absorb (do
    let toText n = Data.Text.pack (show n)
    let fromText text = do
            let string = Data.Text.unpack text
            fmap DoubleLit (Text.Read.readMaybe string)
    text <- editText (toText n)
    return (fromText text) )
dhallEdit (IntegerLit n) = absorb (do
    let toText n = Data.Text.pack (show n)
    let fromText text = do
            let string = Data.Text.unpack text
            fmap IntegerLit (Text.Read.readMaybe string)
    text <- editText (toText n)
    return (fromText text) )
dhallEdit (NaturalLit n) = absorb (do
    let toText n = "+" <> Data.Text.pack (show n)
    let fromText text = do
            case Data.Text.unpack text of
                '+':string -> fmap NaturalLit (Text.Read.readMaybe string)
                _          -> Nothing
    text <- editText (toText n)
    return (fromText text) )
dhallEdit (RecordLit kvs) = do
    let process key val = do
            let adapt widget =
                        str (Data.Text.Lazy.unpack (key <> ":"))
                    <=> (str "  " <+> widget)
            modifyWidget adapt (dhallEdit val)
    kvs' <- Data.Map.traverseWithKey process kvs
    return (RecordLit kvs')
dhallEdit (ListLit t xs) = do
    let process val = do
            let adapt widget = str "• " <+> widget
            modifyWidget adapt (dhallEdit val)
    xs' <- traverse process xs
    return (ListLit t xs')
dhallEdit (OptionalLit t xs) = do
    let process val = do
            let adapt widget = str "• " <+> widget
            modifyWidget adapt (dhallEdit val)
    xs' <- traverse process xs
    return (OptionalLit t xs')
dhallEdit (UnionLit key val kts) = do
    let adapt widget =
                str (Data.Text.Lazy.unpack (key <> ":"))
            <=> (str "  " <+> widget)
    val' <- modifyWidget adapt (dhallEdit val)
    return (UnionLit key val' kts)
