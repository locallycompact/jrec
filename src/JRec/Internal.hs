{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE CPP #-}
{-# LANGUAGE ConstraintKinds #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE ExistentialQuantification #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE FunctionalDependencies #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE MagicHash #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE PolyKinds #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE RoleAnnotations #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE UnboxedTuples #-}
{-# LANGUAGE UndecidableInstances #-}

-- Based on https://github.com/agrafix/superrecord. The original doesn't
-- export a lot of good things, and it was easier to just copy the
-- implementation since we don't need much out of it.

module JRec.Internal where

import Control.DeepSeq
import Control.Monad.Reader
import qualified Control.Monad.State as S
import Data.Aeson
import Data.Aeson.Types (Parser)
import Data.Constraint
import Data.List (intercalate)
import Data.Maybe (catMaybes)
import Data.Proxy
import qualified Data.Text as T
import Data.Typeable
import GHC.Base (Any, Int (..))
import GHC.Generics
import GHC.OverloadedLabels
import GHC.Prim
import GHC.ST (ST (..), runST)
import GHC.TypeLits
import qualified Optics.Lens as OL
import Unsafe.Coerce
import Prelude

-- | Field named @l@ labels value of type @t@ adapted from the awesome /labels/ package.
-- Example: @(#name := \"Chris\") :: (\"name\" := String)@
data label := value = KnownSymbol label => FldProxy label := !value

deriving instance Typeable (:=)

deriving instance Typeable (label := value)

infix 6 :=

instance (Eq value) => Eq (label := value) where
  (_ := x) == (_ := y) = x == y
  {-# INLINE (==) #-}

instance (Ord value) => Ord (label := value) where
  compare (_ := x) (_ := y) = x `compare` y
  {-# INLINE compare #-}

instance
  (Show t) =>
  Show (l := t)
  where
  showsPrec p (l := t) =
    showParen (p > 10) (showString ("#" ++ symbolVal l ++ " := " ++ show t))

unpackAssign :: (label := value) -> value
unpackAssign (_ := value) = value
{-# INLINE unpackAssign #-}

-- | A proxy witness for a label. Very similar to 'Proxy', but needed to implement
-- a non-orphan 'IsLabel' instance
data FldProxy (t :: Symbol)
  = FldProxy
  deriving (Show, Read, Eq, Ord, Typeable)

instance l ~ l' => IsLabel (l :: Symbol) (FldProxy l') where
  fromLabel = FldProxy

-- | Internal record type. When manually writing an explicit type signature for
-- a record, use 'Record' instead. For abstract type signatures 'Rec' will work
-- well.
data Rec (lts :: [*]) = MkRec
  { _unRec :: SmallArray# Any -- Note that the values are physically in reverse order
  }

data JSONOptions = JSONOptions
  {fieldTransform :: String -> String}

defaultJSONOptions :: JSONOptions
defaultJSONOptions = JSONOptions {fieldTransform = id}

type role Rec representational

instance
  ( RecApply lts lts Show
  ) =>
  Show (Rec lts)
  where
  show rec = "{" ++ formatted ++ "}"
    where formatted = intercalate ", " $ map (\(k, v) -> k ++ " = " ++ v) $ showRec rec

instance RecEq lts lts => Eq (Rec lts) where
  (==) (a :: Rec lts) (b :: Rec lts) = recEq a b (Proxy :: Proxy lts)
  {-# INLINE (==) #-}

instance RecOrd lts lts => Ord (Rec lts) where
  compare (a :: Rec lts) (b :: Rec lts) = recOrd a b (Proxy :: Proxy lts)
  {-# INLINE compare #-}

#ifdef WITH_AESON
instance
  ( RecApply lts lts EncodeField
  ) =>
  ToJSON (Rec lts)
  where
  toJSON = recToValue defaultJSONOptions
  toEncoding = recToEncoding defaultJSONOptions

instance (RecSize lts ~ s, KnownNat s, RecJsonParse lts) => FromJSON (Rec lts) where
  parseJSON = recJsonParser defaultJSONOptions

#endif

instance RecNfData lts lts => NFData (Rec lts) where
  rnf = recNfData (Proxy :: Proxy lts)

newtype ForallST a = ForallST {unForallST :: forall s. ST s a}

-- Hack needed because $! doesn't have the same special treatment $ does to work with ST yet
runST' :: (forall s. ST s a) -> a
runST' !s = runST s

-- | An empty record
rnil :: Rec '[]
rnil = create (unsafeRNil 0)
{-# INLINE rnil #-}

create :: (forall s. ST s (Rec xs)) -> Rec xs
create = runST'

unsafeRNil :: Int -> ST s (Rec '[])
unsafeRNil (I# n#) =
  ST $ \s# ->
    case newSmallArray# n# (error "No value") s# of
      (# s'#, arr# #) ->
        case unsafeFreezeSmallArray# arr# s'# of
          (# s''#, a# #) -> (# s''#, MkRec a# #)
{-# INLINE unsafeRNil #-}

-- | Prepend a record entry to a record 'Rec'. Assumes that the record was created with
-- 'unsafeRNil' and still has enough free slots, mutates the original 'Rec' which should
-- not be reused after
--
-- NOTE: doesn't use 'KeyDoesNotExist' because we rely on the fact that in
-- euler-ps there were no duplicate keys
unsafeRCons ::
  forall l t lts size s.
  ( RecSize lts ~ size,
    KnownNat size
    -- KeyDoesNotExist l lts
  ) =>
  l := t ->
  Rec lts ->
  ST s (Rec (l := t ': lts))
unsafeRCons (_ := val) (MkRec vec#) =
  ST $ \s# ->
    case unsafeThawSmallArray# vec# s# of
      (# s'#, arr# #) ->
        -- Write the value to be cons'ed at the *end* (hence size#) of the
        -- array, because `Rec` stores values in reverse order.
        case writeSmallArray# arr# size# (unsafeCoerce# val) s'# of
          s''# ->
            case unsafeFreezeSmallArray# arr# s''# of
              (# s'''#, a# #) -> (# s'''#, MkRec a# #)
  where
    !(I# size#) = fromIntegral $ natVal' (proxy# :: Proxy# size)
{-# INLINE unsafeRCons #-}

-- | Get the i-th value as Any unsafely.
-- No boundary check. Also ther caller is responsible for coerceing to correct type.
-- Intented for internal use only.
unsafeGet ::
  forall lts.
  Int ->
  Rec lts ->
  Any
unsafeGet (I# index#) (MkRec vec#) =
  let size# = sizeofSmallArray# vec#
  in case indexSmallArray# vec# (size# -# index# -# 1#) of
       (# a# #) -> a#
{-# INLINE unsafeGet #-}

-- Not in superrecord
recCopy :: forall lts rts. RecCopy lts lts rts => Rec lts -> Rec rts
recCopy r@(MkRec vec#) =
  let size# = sizeofSmallArray# vec#
   in runST' $
        ST $ \s# ->
          case newSmallArray# size# (error "No value") s# of
            (# s'#, arr# #) ->
              case recCopyInto (Proxy @lts) r (Proxy @rts) arr# s'# of
                s''# ->
                  case unsafeFreezeSmallArray# arr# s''# of
                    (# s'''#, a# #) -> (# s'''#, MkRec a# #)
{-# INLINE recCopy #-}

class RecCopy (pts :: [*]) (lts :: [*]) (rts :: [*]) where
  recCopyInto ::
    Proxy pts ->
    Rec lts ->
    Proxy rts ->
    SmallMutableArray# s Any ->
    State# s ->
    State# s

instance RecCopy '[] lts rts where
  recCopyInto _ _ _ _ s# = s#

instance
  ( Has l rts t,
    Has l lts t,
    nts ~ RemoveAccessTo l (l := t ': pts),
    RecCopy nts lts rts
  ) =>
  RecCopy (l := t ': pts) lts rts
  where
  recCopyInto _ lts prxy tgt# s# =
    let lbl :: FldProxy l
        lbl = FldProxy
        val = get lbl lts
        !(I# index#) =
          fromIntegral (natVal' (proxy# :: Proxy# (RecTyIdxH 0 l rts)))
        size# = sizeofSmallMutableArray# tgt#
     in case writeSmallArray# tgt# (size# -# index# -# 1#) (unsafeCoerce# val) s# of
          s'# -> recCopyInto (Proxy :: Proxy nts) lts prxy tgt# s'#

type family RecAll (c :: u -> Constraint) (rs :: [u]) :: Constraint where
  RecAll c '[] = ()
  RecAll c (r ': rs) = (c r, RecAll c rs)

type family KeyDoesNotExist (l :: Symbol) (lts :: [*]) :: Constraint where
  KeyDoesNotExist l '[] = 'True ~ 'True
  KeyDoesNotExist l (l := t ': lts) =
    TypeError
      ( 'Text "Duplicate key " ':<>: 'Text l
      )
  KeyDoesNotExist q (l := t ': lts) = KeyDoesNotExist q lts

type family Reverse (xs :: [*]) where
  Reverse '[] = '[]
  Reverse (x ': xs) = RecAppend (Reverse xs) '[x]

type family Insert (a :: *) (xs :: [*]) where
  Insert x '[] = x ': '[]
  Insert (a := v) (a := _ ': xs) = a := v ': xs
  Insert a (x ': xs) = x ': Insert a xs

type family Union xs ys where
  Union xs '[] = xs
  Union xs (y := t ': ys) = Union (Insert (y := t) xs) ys

-- TODO: Rename to `Append`, because it just deals with general type list?
type family RecAppend lhs rhs where
  RecAppend '[] rhs = rhs
  RecAppend (x ': xs) rhs = x ': RecAppend xs rhs

type family RecSize (lts :: [*]) :: Nat where
  RecSize '[] = 0
  RecSize (l := t ': lts) = 1 + RecSize lts

type family RecTyIdxH (i :: Nat) (l :: Symbol) (lts :: [*]) :: Nat where
  RecTyIdxH idx l (l := t ': lts) = idx
  RecTyIdxH idx m (l := t ': lts) = RecTyIdxH (1 + idx) m lts
  RecTyIdxH idx m '[] =
    TypeError
      ( 'Text "Could not find label "
          ':<>: 'Text m
      )

type family RecTy (l :: Symbol) (lts :: [*]) :: k where
  RecTy l (l := t ': lts) = t
  RecTy q (l := t ': lts) = RecTy q lts

-- | Require a record to contain at least the listed labels
type family HasOf (req :: [*]) (lts :: [*]) :: Constraint where
  HasOf (l := t ': req) lts = (Has l lts t, HasOf req lts)
  HasOf '[] lts = 'True ~ 'True

-- | Require a record to contain a label
type Has l lts v =
  ( RecTy l lts ~ v,
    -- KnownNat (RecSize lts),
    KnownNat (RecTyIdxH 0 l lts)
  )

-- | Get an existing record field
get ::
  forall l v lts.
  ( Has l lts v
  ) =>
  FldProxy l ->
  Rec lts ->
  v
get _ r =
  let !index = fromIntegral (natVal' (proxy# :: Proxy# (RecTyIdxH 0 l lts)))
  in unsafeCoerce $ unsafeGet index r
{-# INLINE get #-}

-- | Alias for 'get'
(&.) :: forall l v lts. (Has l lts v) => Rec lts -> FldProxy l -> v
(&.) = flip get

infixl 3 &.

type family Set l lts v where
  Set l '[] v = '[]
  Set l ((l := u) ': xs) v = (l := v) ': xs
  Set l (x ': xs) v = x ': Set l xs v

-- | Update an existing record field
set ::
  forall l v lts v' lts'.
  (Has l lts v, Set l lts v' ~ lts') =>
  FldProxy l ->
  v' ->
  Rec lts ->
  Rec lts'
set _ !val (MkRec vec#) =
  let !(I# index#) = fromIntegral (natVal' (proxy# :: Proxy# (RecTyIdxH 0 l lts)))
      -- Unlike superrecord - calculating size dynamically instead of statically
      size# = sizeofSmallArray# vec#
      dynVal :: Any
      !dynVal = unsafeCoerce# val
      r2 =
        runST' $
          ST $ \s# ->
            case newSmallArray# size# (error "No value") s# of
              (# s'#, arr# #) ->
                case copySmallArray# vec# 0# arr# 0# size# s'# of
                  s''# ->
                    case writeSmallArray# arr# (size# -# index# -# 1#) dynVal s''# of
                      s'''# ->
                        case unsafeFreezeSmallArray# arr# s'''# of
                          (# s''''#, a# #) -> (# s''''#, MkRec a# #)
   in r2
{-# INLINE set #-}

-- | Update an existing record field
modify ::
  forall l v lts v' lts'.
  (Has l lts v, Set l lts v' ~ lts') =>
  FldProxy l ->
  (v -> v') ->
  Rec lts ->
  Rec lts'
modify lbl fun r = set lbl (fun $ get lbl r) r
{-# INLINE modify #-}

-- | Constructor for field accessor paths
data lbl :& more = FldProxy lbl :& more

infixr 8 :&

-- | Constructor for field accessor paths
(&:) :: FldProxy q -> more -> q :& more
(&:) = (:&)
{-# INLINE (&:) #-}

infixr 8 &:

-- | Specialized version of (&:) to help writing the last piece of the path w/o
-- confusing the type checker
(&:-) :: FldProxy q -> FldProxy r -> q :& FldProxy r
(&:-) = (:&)
{-# INLINE (&:-) #-}

infixr 8 &:-

-- | Helper function to allow to clearing specify unknown 'IsLabel' cases
fld :: FldProxy l -> FldProxy l
fld = id

type family RecDeepTy (ps :: r) (lts :: [*]) :: * where
  RecDeepTy (l :& more) (l := Rec t ': lts) = RecDeepTy more t
  RecDeepTy (l :& more) (l := t ': lts) = t
  RecDeepTy (l :& more) (q := t ': lts) = RecDeepTy (l :& more) lts
  RecDeepTy (FldProxy l) '[l := t] = t
  RecDeepTy l '[l := t] = t

-- | Combine two records
--
-- NOTE: changed from original superrecord to not require a 'Sort'
combine ::
  forall lhs rhs res.
  res ~ RecAppend lhs rhs =>
  Rec lhs ->
  Rec rhs ->
  Rec res
combine (MkRec arr0#) (MkRec arr1#) =
  let !size0# = sizeofSmallArray# arr0#
      !size1# = sizeofSmallArray# arr1#
   in runST' $
        ST $ \s# ->
          case newSmallArray# (size0# +# size1#) (error "No value") s# of
            (# s'#, arr# #) ->
              case copySmallArray# arr1# 0# arr# 0# size1# s'# of
                s''# ->
                  case copySmallArray# arr0# 0# arr# size1# size0# s''# of
                    s'''# ->
                      case unsafeFreezeSmallArray# arr# s'''# of
                        (# s''''#, a# #) -> (# s''''#, MkRec a# #)
{-# INLINE combine #-}

-- | Union two records (left-biased)
union ::
  forall lhs rhs res.
  ( KnownNat (RecSize lhs),
    KnownNat (RecSize rhs),
    KnownNat (RecSize res),
    res ~ Union lhs rhs,
    RecCopy lhs lhs res,
    RecCopy rhs rhs res
  ) =>
  Rec lhs ->
  Rec rhs ->
  Rec res
union lts rts =
  let !(I# size#) =
        fromIntegral $ natVal' (proxy# :: Proxy# (RecSize (Union lhs rhs)))
   in runST' $
        ST $ \s# ->
          case newSmallArray# size# (error "No value") s# of
            (# s'#, arr# #) ->
              -- Copy rhs first, so that lhs can override later so as to retain
              -- the left-biased semantics of union.
              case recCopyInto (Proxy :: Proxy rhs) rts (Proxy :: Proxy res) arr# s'# of
                s''# ->
                  case recCopyInto (Proxy :: Proxy lhs) lts (Proxy :: Proxy res) arr# s''# of
                    s'''# ->
                      case unsafeFreezeSmallArray# arr# s'''# of
                        (# s''''#, a# #) -> (# s''''#, MkRec a# #)
{-# INLINE union #-}

-- | Insert a field
--
-- Insert at beginning, unless the field already exists, in which case set it
-- directly.
insert ::
  forall l v rhs res.
  ( KnownNat (RecSize rhs),
    KnownNat (RecSize res),
    res ~ Reverse (Insert (l := v) (Reverse rhs)),
    RecCopy '[l := v] '[l := v] res,
    RecCopy rhs rhs res
  ) =>
  l := v ->
  Rec rhs ->
  Rec res
insert (l := v) rts =
  let !(I# size#) =
        fromIntegral $ natVal' (proxy# :: Proxy# (RecSize res))
   in runST' $ do
        single <- unsafeRCons (l := v) =<< unsafeRNil 1
        ST $ \s# ->
          case newSmallArray# size# (error "No value") s# of
            (# s'#, arr# #) ->
              case recCopyInto (Proxy :: Proxy rhs) rts (Proxy :: Proxy res) arr# s'# of
                s''# ->
                  case recCopyInto (Proxy :: Proxy '[l := v]) single (Proxy :: Proxy res) arr# s''# of
                    s'''# ->
                      case unsafeFreezeSmallArray# arr# s'''# of
                        (# s''''#, a# #) -> (# s''''#, MkRec a# #)
{-# INLINE insert #-}

-- | Alias for 'combine'
(++:) ::
  forall lhs rhs res.
  res ~ RecAppend lhs rhs =>
  Rec lhs ->
  Rec rhs ->
  Rec res
(++:) = combine
{-# INLINE (++:) #-}

data RecFields (flds :: [Symbol]) where
  RFNil :: RecFields '[]
  RFCons :: KnownSymbol f => FldProxy f -> RecFields xs -> RecFields (f ': xs)

recKeys :: forall t (lts :: [*]). RecKeys lts => t lts -> [String]
recKeys = recKeys' . recFields

recKeys' :: RecFields lts -> [String]
recKeys' x =
  case x of
    RFNil -> []
    RFCons q qs -> symbolVal q : recKeys' qs

-- | Get keys of a record on value and type level
class RecKeys (lts :: [*]) where
  type RecKeysT lts :: [Symbol]
  recFields :: t lts -> RecFields (RecKeysT lts)

instance RecKeys '[] where
  type RecKeysT '[] = '[]
  recFields _ = RFNil

instance (KnownSymbol l, RecKeys lts) => RecKeys (l := t ': lts) where
  type RecKeysT (l := t ': lts) = (l ': RecKeysT lts)
  recFields (_ :: f (l := t ': lts)) =
    let lbl :: FldProxy l
        lbl = FldProxy
        more :: Proxy lts
        more = Proxy
     in (lbl `RFCons` recFields more)

-- | Apply a function to each key element pair for a record
reflectRec ::
  forall c r lts.
  (RecApply lts lts c) =>
  Proxy c ->
  (forall a. c a => String -> a -> r) ->
  Rec lts ->
  [r]
reflectRec _ f r =
  reverse $
    recApply (\(Dict :: Dict (c a)) s v xs -> (f s v : xs)) r (Proxy :: Proxy lts) []
{-# INLINE reflectRec #-}

-- | Fold over all elements of a record
reflectRecFold ::
  forall c r lts.
  (RecApply lts lts c) =>
  Proxy c ->
  (forall a. c a => String -> a -> r -> r) ->
  Rec lts ->
  r ->
  r
reflectRecFold _ f r =
  recApply (\(Dict :: Dict (c a)) s v x -> f s v x) r (Proxy :: Proxy lts)
{-# INLINE reflectRecFold #-}

-- | Convert all elements of a record to a 'String'
showRec :: forall lts. (RecApply lts lts Show) => Rec lts -> [(String, String)]
showRec = reflectRec @Show Proxy (\k v -> (k, show v))

class ToJSON a => EncodeField a where
  encodeField :: a -> Maybe Value
  encodeKV :: T.Text -> a -> Series

instance ToJSON a => EncodeField a where
  encodeField = pure . toJSON
  encodeKV = (.=)

instance {-# OVERLAPS #-} ToJSON a => EncodeField (Maybe a) where
  encodeField = fmap toJSON
  encodeKV _ Nothing = mempty
  encodeKV k v = k .= v

recToValue :: forall lts. (RecApply lts lts EncodeField) => JSONOptions -> Rec lts -> Value
recToValue options r =
  object $ catMaybes $ reflectRec @EncodeField Proxy (\k v -> (T.pack (fieldTransform options k),) <$> encodeField v) r

recToEncoding :: forall lts. (RecApply lts lts EncodeField) => JSONOptions -> Rec lts -> Encoding
recToEncoding options r =
  pairs $ mconcat $ reflectRec @EncodeField Proxy (\k v -> (T.pack (fieldTransform options k) `encodeKV` v)) r

recJsonParser ::
  forall lts s.
  (RecSize lts ~ s, KnownNat s, RecJsonParse lts) =>
  (JSONOptions -> Value -> Parser (Rec lts))
recJsonParser options =
  withObject "Record" $ \o ->
    (\(ForallST act) -> create act) <$> recJsonParse options initSize o
  where
    initSize = fromIntegral $ natVal' (proxy# :: Proxy# s)

-- | Machinery needed to implement 'reflectRec'
class RecApply (rts :: [*]) (lts :: [*]) c where
  recApply :: (forall a. Dict (c a) -> String -> a -> b -> b) -> Rec rts -> Proxy lts -> b -> b

instance RecApply rts '[] c where
  recApply _ _ _ b = b

instance
  ( KnownSymbol l,
    RecApply rts (RemoveAccessTo l lts) c,
    Has l rts v,
    c v
  ) =>
  RecApply rts (l := t ': lts) c
  where
  recApply f r (_ :: Proxy (l := t ': lts)) b =
    let lbl :: FldProxy l
        lbl = FldProxy
        val = get lbl r
        res = f Dict (symbolVal lbl) val b
        pNext :: Proxy (RemoveAccessTo l (l := t ': lts))
        pNext = Proxy
     in recApply f r pNext res

-- | Machinery to implement equality
class RecEq (rts :: [*]) (lts :: [*]) where
  recEq :: Rec rts -> Rec rts -> Proxy lts -> Bool

instance RecEq rts '[] where
  recEq _ _ _ = True

instance
  ( RecEq rts (RemoveAccessTo l lts),
    Has l rts v,
    Eq v
  ) =>
  RecEq rts (l := t ': lts)
  where
  recEq r1 r2 (_ :: Proxy (l := t ': lts)) =
    let lbl :: FldProxy l
        lbl = FldProxy
        val = get lbl r1
        val2 = get lbl r2
        res = val == val2
        pNext :: Proxy (RemoveAccessTo l (l := t ': lts))
        pNext = Proxy
     in res && recEq r1 r2 pNext

-- | Machinery to implement order
class RecEq rts lts => RecOrd (rts :: [*]) (lts :: [*]) where
  recOrd :: Rec rts -> Rec rts -> Proxy lts -> Ordering

instance RecOrd rts '[] where
  recOrd _ _ _ = EQ

instance
  ( RecOrd rts (RemoveAccessTo l lts),
    Has l rts v,
    Ord v
  ) =>
  RecOrd rts (l := t ': lts)
  where
  recOrd r1 r2 (_ :: Proxy (l := t ': lts)) =
    let lbl :: FldProxy l
        lbl = FldProxy
        val1 = get lbl r1
        val2 = get lbl r2
        ord = compare val1 val2
        pNext :: Proxy (RemoveAccessTo l (l := t ': lts))
        pNext = Proxy
     in if ord == EQ then recOrd r1 r2 pNext else ord

-- TODO: this probably slows typechecking in euler-ps, and should not be needed
type family RemoveAccessTo (l :: Symbol) (lts :: [*]) :: [*] where
  RemoveAccessTo l (l := t ': lts) = RemoveAccessTo l lts
  RemoveAccessTo q (l := t ': lts) = (l := t ': RemoveAccessTo q lts)
  RemoveAccessTo q '[] = '[]

-- | Machinery to implement parseJSON
class RecJsonParse (lts :: [*]) where
  recJsonParse :: JSONOptions -> Int -> Object -> Parser (ForallST (Rec lts))

instance RecJsonParse '[] where
  recJsonParse _ initSize _ = pure (ForallST (unsafeRNil initSize))

class FromJSON a => ParseField a where
  parseField :: Object -> T.Text -> Parser a

instance FromJSON a => ParseField a where
  parseField = (.:)

instance {-# OVERLAPS #-} FromJSON a => ParseField (Maybe a) where
  parseField = (.:?)

instance
  ( KnownSymbol l,
    FromJSON t,
    ParseField t,
    RecJsonParse lts,
    RecSize lts ~ s,
    KnownNat s,
    KeyDoesNotExist l lts
  ) =>
  RecJsonParse (l := t ': lts)
  where
  recJsonParse options initSize obj = do
    let lbl :: FldProxy l
        lbl = FldProxy
    rest <- recJsonParse options initSize obj
    (v :: t) <- obj `parseField` T.pack (fieldTransform options (symbolVal lbl))
    pure $ ForallST (unsafeRCons (lbl := v) =<< unForallST rest)

-- | Machinery for NFData
class RecNfData (lts :: [*]) (rts :: [*]) where
  recNfData :: Proxy lts -> Rec rts -> ()

instance RecNfData '[] rts where
  recNfData _ _ = ()

instance
  ( Has l rts v,
    NFData v,
    RecNfData (RemoveAccessTo l lts) rts
  ) =>
  RecNfData (l := t ': lts) rts
  where
  recNfData (_ :: (Proxy (l := t ': lts))) r =
    let !v = get (FldProxy :: FldProxy l) r
        pNext :: Proxy (RemoveAccessTo l (l := t ': lts))
        pNext = Proxy
     in deepseq v (recNfData pNext r)

-- | Conversion helper to bring a Haskell type to a record. Note that the
-- native Haskell type must be an instance of 'Generic'
class FromNative a lts | a -> lts where
  fromNative' :: a x -> Rec lts

instance FromNative cs lts => FromNative (D1 m cs) lts where
  fromNative' (M1 xs) = fromNative' xs

instance FromNative cs lts => FromNative (C1 m cs) lts where
  fromNative' (M1 xs) = fromNative' xs

instance FromNative U1 '[] where
  fromNative' U1 = rnil

instance
  ( KnownSymbol name
  ) =>
  FromNative (S1 ('MetaSel ('Just name) p s l) (Rec0 t)) '[name := t]
  where
  fromNative' (M1 (K1 t)) =
    create $
      unsafeRCons ((FldProxy :: FldProxy name) := t) =<< unsafeRNil 1

instance
  ( FromNative l lhs,
    FromNative r rhs,
    lts ~ RecAppend lhs rhs,
    RecCopy lhs lhs lts,
    RecCopy rhs rhs lts,
    KnownNat (RecSize lhs),
    KnownNat (RecSize rhs),
    KnownNat (RecSize lhs + RecSize rhs)
  ) =>
  FromNative (l :*: r) lts
  where
  fromNative' (l :*: r) = fromNative' l ++: fromNative' r

-- | Convert a native Haskell type to a record
fromNative :: (Generic a, FromNative (Rep a) lts) => a -> Rec lts
fromNative = fromNative' . from
{-# INLINE fromNative #-}

-- | Conversion helper to bring a record back into a Haskell type. Note that the
-- native Haskell type must be an instance of 'Generic'
class ToNative a lts where
  toNative' :: Rec lts -> a x

instance ToNative cs lts => ToNative (D1 m cs) lts where
  toNative' xs = M1 $ toNative' xs

instance ToNative cs lts => ToNative (C1 m cs) lts where
  toNative' xs = M1 $ toNative' xs

instance ToNative U1 '[] where
  toNative' r = U1

instance
  (Has name lts t) =>
  ToNative (S1 ('MetaSel ('Just name) p s l) (Rec0 t)) lts
  where
  toNative' r =
    M1 $ K1 (get (FldProxy :: FldProxy name) r)

instance
  ( ToNative l lts,
    ToNative r lts
  ) =>
  ToNative (l :*: r) lts
  where
  toNative' r = toNative' r :*: toNative' r

-- | Convert a record to a native Haskell type
toNative :: (Generic a, ToNative (Rep a) lts) => Rec lts -> a
toNative = to . toNative'
{-# INLINE toNative #-}

type Lens s t a b = forall f. Functor f => (a -> f b) -> (s -> f t)

-- | Convert a field label to a lens
lens ::
  (Has l lts v, Set l lts v' ~ lts') => FldProxy l -> Lens (Rec lts) (Rec lts') v v'
lens lbl f r =
  fmap (\v -> set lbl v r) (f (get lbl r))
{-# INLINE lens #-}

opticLens ::
  (Has l lts v, Set l lts v' ~ lts') => FldProxy l -> OL.Lens (Rec lts) (Rec lts') v v'
opticLens lbl =
  OL.lensVL $ lens lbl
{-# INLINE opticLens #-}

class NoConstraint x

instance NoConstraint x

-- | Convert a record into a list of fields.
--
-- | Not present in original superrecord
getFields :: RecApply fields fields NoConstraint => Rec fields -> [Any]
getFields =
  reflectRec @NoConstraint
    Proxy
    (\_ val -> unsafeCoerce (FldProxy @"" := val))
