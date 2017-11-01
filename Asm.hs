{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE PackageImports #-}
module Asm where
import Control.Arrow
import "mtl" Control.Monad.State
import qualified Data.Bimap as BM
import Data.Char
import Data.Int
import Data.List
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as M
import Data.Maybe

import DHC

-- | G-Machine instructions.
data Ins = PrMul | PrAdd | PrSub  -- For testing.
  | Copro Int Int | PushInt Int64 | Push Int | PushGlobal Int
  | MkAp | Slide Int | Split Int | Eval
  | Casejump [(Maybe Int64, [Ins])] | Trap deriving Show

data WasmType = TypeI32 | TypeI64

data WasmOp = GetGlobal Int | SetGlobal Int
  | I64Store | I64Load | I64Add | I64Sub | I64Mul | I64Const Int64
  | I32Store | I32Load | I32Add | I32Sub | I32Const Int
  | I32WrapI64
  | I64Xor | I64Eqz
  | Block | Loop | Br Int | BrTable [Int] | WasmCall Int | Unreachable | End
  deriving Show

nPages = 8

encWasmOp op = case op of
  GetGlobal n -> 0x23 : leb128 n
  SetGlobal n -> 0x24 : leb128 n
  I32Add -> [0x6a]
  I32Sub -> [0x6b]
  I64Add -> [0x7c]
  I64Sub -> [0x7d]
  I64Mul -> [0x7e]
  I64Const n -> 0x42 : sleb128 n
  I32Const n -> 0x41 : sleb128 n
  I32WrapI64 -> [0xa7]
  I64Xor -> [0x85]
  I64Eqz -> [0x50]
  WasmCall n -> 0x10 : leb128 n
  Unreachable -> [0x0]
  End -> [0xb]
  Block -> [2, 0x40]
  Loop -> [3, 0x40]
  Br n -> 0xc : leb128 n
  I64Load -> [0x29, 3, 0]
  I64Store -> [0x37, 3, 0]
  I32Load -> [0x28, 2, 0]
  I32Store -> [0x36, 2, 0]
  BrTable bs -> 0xe : leb128 (length bs - 1) ++ concatMap leb128 bs

wasm :: String -> Either String [Int]
wasm prog = do
  m <- compileMk1 prog
  let
    fs = [evalAsm (4 + length m), addAsm, subAsm, mulAsm, eqAsm]
      ++ ((++ [End]) . concatMap fromIns . snd <$> m)
    sect t xs = t : lenc (varlen xs ++ concat xs)
  pure $ concat
    [ [0, 0x61, 0x73, 0x6d, 1, 0, 0, 0]  -- Magic string, version.
    , sect 1 [encSig [TypeI32] [], encSig [] []]  -- Type section.
    -- Import section.
    -- [0, 0] = external_kind Function, index 0.
    , sect 2 [encStr "i" ++ encStr "f" ++ [0, 0]]
    , sect 3 $ replicate (length fs + 1) [1]  -- Function section.
    , sect 5 [[0, nPages]]  -- Memory section (0 = no-maximum).
    , sect 6  -- Global section (1 = mutable).
      [ [encType TypeI32, 1, 0x41] ++ leb128 (65536*nPages - 4) ++ [0xb]  -- SP
      , [encType TypeI32, 1, 0x41, 0, 0xb]  -- HP
      , [encType TypeI32, 1, 0x41, 0, 0xb]  -- BP
      ]
    -- Export section.
    -- [0, n] = external_kind Function, index n.
    , sect 7 [encStr "e" ++ [0, length fs + 1]]
    , sect 10 $ encProcedure <$> (fs ++  -- Code section.
      [[ WasmCall $ 6 + (fromJust $ elemIndex "run" $ fst <$> m)
      , GetGlobal sp
      , I32Const 4
      , I32Add
      , I32Load
      , SetGlobal bp
      , Block
      , GetGlobal bp
      , I64Load
      , I32WrapI64
      , BrTable [1, 1, 0, 0, 1]
      , End
      , GetGlobal bp
      , I32Const 8
      , I32Add
      , I64Load
      , I32WrapI64
      , WasmCall 0
      , End
      ]])
    ]

encProcedure = lenc . (0:) . concatMap encWasmOp

leb128 :: Int -> [Int]
leb128 n | n < 64    = [n]
         | n < 128   = [128 + n, 0]
         | otherwise = 128 + (n `mod` 128) : leb128 (n `div` 128)

-- TODO: FIX!
sleb128 :: Integral a => a -> [Int]
sleb128 n | n < 64    = [fromIntegral n]
          | n < 128   = [128 + fromIntegral n, 0]
          | otherwise = 128 + (fromIntegral n `mod` 128) : sleb128 (fromIntegral n `div` 128)

varlen xs = leb128 $ length xs

lenc xs = varlen xs ++ xs

encStr s = lenc $ ord <$> s

encType :: WasmType -> Int
encType TypeI32 = 0x7f
encType TypeI64 = 0x7e

-- | Encodes function signature.
encSig :: [WasmType] -> [WasmType] -> [Int]
encSig ins outs = 0x60 : lenc (encType <$> ins) ++ lenc (encType <$> outs)

wAp = 0
wGlobal = 1
wInt = 2
wSum = 3
sp = 0
hp = 1
bp = 2

fromIns instruction = case instruction of
  Trap -> [ Unreachable ]
  Eval -> [ WasmCall 1 ]  -- (Tail call.)
  PushInt n ->
    [ GetGlobal sp  -- [sp] = hp
    , GetGlobal hp
    , I32Store
    , GetGlobal sp  -- sp = sp - 4
    , I32Const 4
    , I32Sub
    , SetGlobal sp
    , GetGlobal hp  -- [hp] = Int
    , I64Const wInt
    , I64Store
    , GetGlobal hp  -- [hp + 8] = n
    , I32Const 8
    , I32Add
    , I64Const n
    , I64Store
    , GetGlobal hp  -- hp = hp + 16
    , I32Const 16
    , I32Add
    , SetGlobal hp
    ]
  Push n ->
    [ GetGlobal sp  -- [sp] = [sp + 4(n + 1)]
    , GetGlobal sp
    , I32Const $ 4*(fromIntegral n + 1)
    , I32Add
    , I32Load
    , I32Store
    , GetGlobal sp  -- sp = sp - 4
    , I32Const 4
    , I32Sub
    , SetGlobal sp
    ]
  MkAp ->
    [ GetGlobal hp  -- [hp] = Ap
    , I64Const wAp
    , I64Store
    , GetGlobal hp  -- [hp + 8] = [sp + 4]
    , I32Const 8
    , I32Add
    , GetGlobal sp
    , I32Const 4
    , I32Add
    , I32Load
    , I32Store
    , GetGlobal hp  -- [hp + 12] = [sp + 8]
    , I32Const 12
    , I32Add
    , GetGlobal sp
    , I32Const 8
    , I32Add
    , I32Load
    , I32Store
    , GetGlobal sp  -- [sp + 8] = hp
    , I32Const 8
    , I32Add
    , GetGlobal hp
    , I32Store
    , GetGlobal sp  -- sp = sp + 4
    , I32Const 4
    , I32Add
    , SetGlobal sp
    , GetGlobal hp  -- hp = hp + 16
    , I32Const 16
    , I32Add
    , SetGlobal hp
    ]
  PushGlobal g ->
    [ GetGlobal sp  -- [sp] = hp
    , GetGlobal hp
    , I32Store
    , GetGlobal sp  -- sp = sp - 4
    , I32Const 4
    , I32Sub
    , SetGlobal sp
    , GetGlobal hp  -- [hp] = Global
    , I64Const wGlobal
    , I64Store
    , GetGlobal hp  -- [hp + 8] = n
    , I32Const 8
    , I32Add
    , I64Const $ fromIntegral g
    , I64Store
    , GetGlobal hp  -- hp = hp + 16
    , I32Const 16
    , I32Add
    , SetGlobal hp
    ]
  Slide 0 -> []
  Slide n ->
    [ GetGlobal sp  -- [sp + 4*(n + 1)] = [sp + 4]
    , I32Const $ 4*(fromIntegral n + 1)
    , I32Add
    , GetGlobal sp
    , I32Const 4
    , I32Add
    , I32Load
    , I32Store
    , GetGlobal sp  -- sp = sp + 4*n
    , I32Const $ 4*fromIntegral n
    , I32Add
    , SetGlobal sp
    ]
  Copro m n ->
    [ GetGlobal hp  -- [hp] = Sum
    , I64Const wSum
    , I64Store
    , GetGlobal hp  -- [hp + 8] = m
    , I32Const 8
    , I32Add
    , I32Const m
    , I32Store
    ] ++ concat [
      [ GetGlobal hp  -- [hp + 8 + 4*i] = [sp + 4*i]
      , I32Const $ 8 + 4*i
      , I32Add
      , GetGlobal sp
      , I32Const $ 4*i
      , I32Add
      , I32Load
      , I32Store ] | i <- [1..n]] ++
    [ GetGlobal sp  -- sp = sp + 4*n
    , I32Const $ 4*n
    , I32Add
    , SetGlobal sp
    , GetGlobal sp  -- [sp] = hp
    , GetGlobal hp
    , I32Store
    , GetGlobal sp  -- sp = sp - 4
    , I32Const 4
    , I32Sub
    , SetGlobal sp
    , GetGlobal hp  -- hp = hp + 16 + floor(n / 2) * 8
    , I32Const $ 16 + 8 * (n `div` 2)
    , I32Add
    , SetGlobal hp
    ]
  Casejump alts0 -> let
    -- TODO: This compiles Int case statements incorrectly.
      (underscore, unsortedAlts) = partition (isNothing . fst) alts0
      alts = sortOn fst unsortedAlts
      catchall = if null underscore then [Trap] else snd $ head underscore
      tab = zip (fromJust . fst <$> alts) [0..]
      m = 1 + (maximum $ fromJust . fst <$> alts)
    -- [sp + 4] should be:
    -- 0: wSum
    -- 8: "Enum"
    -- 12, 16, ...: fields
    in [ GetGlobal sp  -- bp = [sp + 4]
    , I32Const 4
    , I32Add
    , I32Load
    , SetGlobal bp

    , Block]
    ++ replicate (length alts + 1) Block ++
    [ GetGlobal bp  -- [bp + 8]
    , I32Const 8
    , I32Add
    , I32Load
    , BrTable [fromIntegral $ fromMaybe (length alts) $ lookup i tab | i <- [0..m]]]
    ++ concat (zipWith (++) [End : concatMap fromIns ins | (_, ins) <- alts]
      (pure . Br <$> reverse [1..length alts]))
      ++ (End : concatMap fromIns catchall ++ [End])
  Split 0 -> [GetGlobal sp, I32Const 4, I32Add, SetGlobal sp]
  Split n ->
    [ GetGlobal sp  -- bp = [sp + 4]
    , I32Const 4
    , I32Add
    , I32Load
    , SetGlobal bp
    , GetGlobal sp  -- sp = sp + 4
    , I32Const 4
    , I32Add
    , SetGlobal sp
    ] ++ concat [
      [ GetGlobal sp  -- [sp - 4*(n - i)] = [bp + 8 + 4*i]
      , I32Const $ 4*(n - i)
      , I32Sub
      , GetGlobal bp
      , I32Const $ 8 + 4*i
      , I32Add
      , I32Load
      , I32Store
      ] | i <- [1..n]] ++
    [ GetGlobal sp  -- sp = sp - 4*n
    , I32Const $ 4*n
    , I32Sub
    , SetGlobal sp
    ]

evalAsm n =
  [ Block
  , Loop
  , GetGlobal sp  -- bp = [sp + 4]
  , I32Const 4
  , I32Add
  , I32Load
  , SetGlobal bp
  , Block
  , GetGlobal bp
  , I32Load
  , BrTable [0, 2, 3]  -- case [bp]
  , End  -- 0: Ap
  , GetGlobal sp   -- [sp + 4] = [bp + 12]
  , I32Const 4
  , I32Add
  , GetGlobal bp
  , I32Const 12
  , I32Add
  , I32Load
  , I32Store
  , GetGlobal sp  -- [sp] = [bp + 8]
  , GetGlobal bp
  , I32Const 8
  , I32Add
  , I32Load
  , I32Store
  , GetGlobal sp  -- sp = sp - 4
  , I32Const 4
  , I32Sub
  , SetGlobal sp
  , Br 0
  , End  -- 1: Ap loop.
  , End  -- 2: Global
  , GetGlobal sp  -- sp = sp + 4
  , I32Const 4
  , I32Add
  , SetGlobal sp
  ] ++ replicate n Block ++
  [ GetGlobal bp  -- case [bp + 8]
  , I32Const 8
  , I32Add
  , I32Load
  , BrTable [0..n]
  ] ++ concat [[End, WasmCall $ 1 + i, Br (n - i)] | i <- [1..n]] ++
  [ End  -- 3: Other. It's already WHNF.
  ]

addAsm = intAsm I64Add
subAsm = intAsm I64Sub
mulAsm = intAsm I64Mul

intAsm op = concatMap fromIns [Push 1, Eval, Push 1, Eval ] ++
  [ GetGlobal hp  -- [hp] = Int
  , I64Const wInt
  , I64Store
  -- [hp + 8] = [[sp + 4] + 8] `op` [[sp + 8] + 8]
  , GetGlobal hp  -- PUSH hp + 8
  , I32Const 8
  , I32Add
  , GetGlobal sp  -- PUSH [[sp + 4] + 8]
  , I32Const 4
  , I32Add
  , I32Load
  , I32Const 8
  , I32Add
  , I64Load
  , GetGlobal sp  -- PUSH [[sp + 8] + 8]
  , I32Const 8
  , I32Add
  , I32Load
  , I32Const 8
  , I32Add
  , I64Load
  , op
  , I64Store
  , GetGlobal sp  -- [sp + 8] = hp
  , I32Const 8
  , I32Add
  , GetGlobal hp
  , I32Store
  , GetGlobal sp  -- sp = sp + 4
  , I32Const 4
  , I32Add
  , SetGlobal sp
  , GetGlobal hp  -- hp = hp + 16
  , I32Const 16
  , I32Add
  , SetGlobal hp
  ] ++ fromIns (Slide 2) ++ [End]

eqAsm = concatMap fromIns [Push 1, Eval, Push 1, Eval ] ++
  [ GetGlobal hp  -- [hp] = Int
  , I64Const wSum
  , I64Store
  -- [hp + 8] = [[sp + 4] + 8] == [[sp + 8] + 8]
  , GetGlobal hp  -- PUSH hp + 8
  , I32Const 8
  , I32Add
  , GetGlobal sp  -- PUSH [[sp + 4] + 8]
  , I32Const 4
  , I32Add
  , I32Load
  , I32Const 8
  , I32Add
  , I64Load
  , GetGlobal sp  -- PUSH [[sp + 8] + 8]
  , I32Const 8
  , I32Add
  , I32Load
  , I32Const 8
  , I32Add
  , I64Load
  , I64Xor  -- Compare.
  , I64Eqz
  , I32Store
  , GetGlobal sp  -- [sp + 8] = hp
  , I32Const 8
  , I32Add
  , GetGlobal hp
  , I32Store
  , GetGlobal sp  -- sp = sp + 4
  , I32Const 4
  , I32Add
  , SetGlobal sp
  , GetGlobal hp  -- hp = hp + 16
  , I32Const 16
  , I32Add
  , SetGlobal hp
  ] ++ fromIns (Slide 2) ++ [End]

mk1 :: BM.Bimap String Int -> Ast -> State [(String, Int)] [Ins]
mk1 funs ast = case ast of
  I n -> pure [PushInt n]
  t :@ u -> do
    mu <- rec u
    bump 1
    mt <- rec t
    bump (-1)
    pure $ case mt of
      [Copro _ _] -> mu ++ mt
      _ -> concat [mu, mt, [MkAp]]
  Lam a b -> do
    modify' $ \bs -> (a, length bs):bs
    (++ [Slide 1]) <$> rec b
  Var v -> do
    m <- get
    pure $ case lookup v m of
      Just k -> [Push k]
      Nothing -> [PushGlobal $ funs BM.! v]
  Pack n m -> pure [Copro n m]
  Cas expr alts -> do
    me <- rec expr
    xs <- forM alts $ \(p, body) -> do
      orig <- get
      (f, b) <- case fromApList p of
        [I n] -> do
          bump 1
          (,) (Just n) . (++ [Slide 1]) <$> rec body
        (Pack n _:vs) -> do
          bump $ length vs
          modify' $ \bs -> zip (map (\(Var v) -> v) vs) [0..] ++ bs
          bod <- rec body
          pure (Just $ fromIntegral n, Split (length vs) : bod ++ [Slide (length vs)])
        [Var s] -> do
          bump 1
          modify' $ \bs -> (s, 0):bs
          (,) Nothing . (++ [Slide 1]) <$> rec body
      put orig
      pure (f, b)
    pure $ me ++ [Eval, Casejump xs]
  where
    rec = mk1 funs
    bump n = modify' $ map $ second (+n)

fromApList :: Ast -> [Ast]
fromApList (a :@ b) = a : fromApList b
fromApList a = [a]

data Node = NInt Int64 | NAp Int Int | NGlobal Int | NCon Int [Int] deriving Show

prelude :: Map String (Maybe Ast, Type)
prelude = M.fromList $ (second ((,) Nothing) <$>
  [ ("+", TC "Int" :-> TC "Int" :-> TC "Int")
  , ("-", TC "Int" :-> TC "Int" :-> TC "Int")
  , ("*", TC "Int" :-> TC "Int" :-> TC "Int")
  ]) ++
  [ ("False",   (jp 0 0, TC "Bool"))
  , ("True",    (jp 1 0, TC "Bool"))
  , ("Nothing", (jp 0 0, TApp (TC "Maybe") a))
  , ("Just",    (jp 1 1, a :-> TApp (TC "Maybe") a))
  ]
  where
    jp = (Just .) .  Pack
    a = GV "a"

compileMk1 :: String -> Either String [(String, [Ins])]
compileMk1 s = do
  ds <- compileMinimal prelude s
  let funs = BM.fromList $ zip (["+", "-", "*", "Int-=="] ++ (fst <$> ds)) [0..]
  pure $ map (\(s, (d, _)) -> (s, evalState (mk1 funs d) [] ++ [Eval])) ds

-- | Test that interprets G-Machine instructions.
testmk1 :: IO ()
testmk1 = go prog [] [] where
  drop' n as | n > length as = error "BUG!"
             | otherwise     = drop n as
  -- TODO: Deduplicate.
  Right ds = compileMinimal prelude "g n = (case n of 0 -> 1; n -> n * g(n - 1)); f x = x * x; run = f (f 3); run1 = case Just 3 of Just n -> n + 1"
  funs = BM.fromList $ zip (["+", "-", "*", "Int-=="] ++ (fst <$> ds)) [0..]
  m = map (\(s, (d, _)) -> (s, evalState (mk1 funs d) [] ++ [Eval])) ds
  Just prog = lookup "run" m
  go (ins:rest) s h = do
    let k = length h
    case ins of
      PushInt n -> go rest (k:s) ((k, NInt n):h)
      Push n -> go rest (s!!n:s) h
      PushGlobal g -> go rest (k:s) ((k, NGlobal g):h)
      MkAp -> let (s0:s1:srest) = s in go rest (k:srest) ((k, NAp s0 s1):h)
      Slide n -> let (s0:srest) = s in go rest (s0:drop' n srest) h
      Copro n l -> go rest (k:drop l s) ((k, NCon n $ take l s):h)
      Split _ -> let
        (s0:srest) = s
        Just (NCon _ as) = lookup s0 h
        in go rest (as ++ srest) h
      PrAdd -> let
        (s0:s1:srest) = s
        Just (NInt x) = lookup s0 h
        Just (NInt y) = lookup s1 h
        in go rest (k:srest) ((k, NInt $ x + y):h)
      PrSub -> let
        (s0:s1:srest) = s
        Just (NInt x) = lookup s0 h
        Just (NInt y) = lookup s1 h
        in go rest (k:srest) ((k, NInt $ x - y):h)
      PrMul -> let
        (s0:s1:srest) = s
        Just (NInt x) = lookup s0 h
        Just (NInt y) = lookup s1 h
        in go rest (k:srest) ((k, NInt $ x * y):h)
      Eval -> do
        let Just node = lookup (head s) h
        case node of
          NAp a b -> go (Eval:rest) (a:b:tail s) h
          NGlobal g -> let
            p = if g >= 4 then snd (m!!(g - 4)) else case g of
              0 -> [Push 1, Eval, Push 1, Eval, PrAdd, Slide 2]
              1 -> [Push 1, Eval, Push 1, Eval, PrSub, Slide 2]
              2 -> [Push 1, Eval, Push 1, Eval, PrMul, Slide 2]
            in go (p ++ rest) (tail s) h
          _ -> go rest s h
      Casejump alts -> let
        x = case lookup (head s) h of
          Just (NInt n) -> n
          Just (NCon n _) -> fromIntegral n
        body = case lookup (Just x) alts of
          Just b -> b
          _ -> fromJust $ lookup Nothing alts
        in go (body ++ rest) s h
  go [] s h = do
    let Just node = lookup (head s) h
    case node of
      NInt n -> print n
      NCon n _ -> print ("PACK", n)
