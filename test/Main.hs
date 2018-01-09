import Data.Int
import qualified Data.Map as M
import Data.Maybe
import Test.HUnit
import Asm

data Node = NInt Int64 | NAp Int Int | NGlobal Int String | NInd Int | NCon Int [Int] | RealWorld [String] deriving Show

-- | Interprets G-Machine instructions.
gmachine :: String -> String
gmachine prog = if "main" `M.member` funs then
    go (Right <$> [PushGlobal "main", MkAp, Eval]) [0] $ M.singleton 0 $ RealWorld []
  else
    go (Right <$> [PushGlobal "main_", Eval]) [] M.empty
  where
  drop' n as | n > length as = error "BUG!"
             | otherwise     = drop n as
  Right (funs, m) = compileMk1 prog
  arity v = fst $ funs M.! v
  go (fOrIns:rest) s h = either prim exec fOrIns where
    k = M.size h
    heapAdd x = M.insert k x h
    intInt f = go rest (k:srest) $ heapAdd $ NInt $ f x y where
      (s0:s1:srest) = s
      NInt x = h M.! s0
      NInt y = h M.! s1
    intCmp f = go rest (k:srest) $ heapAdd $ NCon (fromEnum $ f x y) [] where
      (s0:s1:srest) = s
      NInt x = h M.! s0
      NInt y = h M.! s1
    boolOp f = go rest (k:srest) $ heapAdd $ NCon (f x y) [] where
      (s0:s1:srest) = s
      NCon x [] = h M.! s0
      NCon y [] = h M.! s1
    rwAdd msg m | RealWorld ms <- m M.! 0 = M.insert 0 (RealWorld $ msg:ms) m
    prim "+" = intInt (+)
    prim "-" = intInt (-)
    prim "*" = intInt (*)
    prim "div" = intInt div
    prim "mod" = intInt mod
    prim "Int-==" = intCmp (==)
    prim "<" = intCmp (<)
    prim ">" = intCmp (>)
    prim "&&" = boolOp min
    prim "||" = boolOp max
    prim "putHello" = go rest (k:tail s) $ rwAdd "hello" $ M.insert k1 (NCon 0 []) $ heapAdd $ NCon 0 [k1, 0] where k1 = k + 1
    prim g   = error $ "unsupported: " ++ g
    exec ins = case ins of
      Trap -> "UNREACHABLE"
      PushInt n -> go rest (k:s) $ heapAdd $ NInt n
      Push n -> go rest (s!!n:s) h
      PushGlobal v -> go rest (k:s) $ heapAdd $ NGlobal (arity v) v
      MkAp -> let (s0:s1:srest) = s in go rest (k:srest) $ heapAdd $ NAp s0 s1
      UpdateInd n -> go rest (tail s) $ M.insert (s!!(n + 1)) (NInd $ head s) h
      UpdatePop n -> go rest (drop' (n + 1) s) $ M.insert (s!!(n + 1)) (NInd $ head s) h
      Alloc n -> go rest ([k..k+n-1]++s) $ M.union h $ M.fromList $ zip [k..k+n-1] (repeat $ NInd 0)
      Slide n -> let (s0:srest) = s in go rest (s0:drop' n srest) h
      Copro n l -> go rest (k:drop' l s) $ heapAdd $ NCon n $ take l s
      Split _ -> let
        (s0:srest) = s
        NCon _ as = h M.! s0
        in go rest (as ++ srest) h
      Eval -> case h M.! head s of
        NInd i -> go (Right Eval:rest) (i:tail s) h
        NAp a _ -> go (Right Eval:rest) (a:s) h
        NGlobal n g -> let
          p | g == "putHello" = [Left "putHello", Right $ UpdatePop 0, Right Eval]
            | otherwise  = case lookup g m of
            Just is -> Right <$> is
            Nothing -> (Right <$> [Push 1, Eval, Push 1, Eval]) ++
              [Left g, Right $ UpdatePop 2, Right Eval]
          debone i = r where NAp _ r = h M.! i
          in go (p ++ rest) ((debone <$> take n (tail s)) ++ drop' n s) h
        _ -> go rest s h
      Casejump alts -> let
        x = case h M.! head s of
          NCon n _ -> fromIntegral n
          _ -> undefined
        body = case lookup (Just x) alts of
          Just b -> b
          _ -> fromJust $ lookup Nothing alts
        in go ((Right <$> body) ++ rest) s h
  go [] [r] h
    | "main_" `M.member` funs = case h M.! r of
      NInt n -> show n
      NCon n _ -> "Pack " ++ show n
      _ -> error "expect NInt or NCon on stack"
    | NCon 0 [_, o] <- h M.! r, RealWorld out <- h M.! o = show out
  go [] s h = error $ "bad stack: " ++ show (s, h)

main :: IO Counts
main = runTestTT $ TestList $ (\(result, source) -> TestCase $
  assertEqual source result $ gmachine source) <$>
    -- Test cases from Peyton Jones and Lester,
    -- "Implementing Functional Languages; a tutorial".
    -- Each case either contains a `main` function of type `IO a`, or
    -- a `main_` function which should be pure, and which we reduce to WHNF.
    [ ("81", "square x = x * x; main_ = square (square 3)")
    , ("3", "i x = x; main_ = i 3")
    , ("3", "id = s k k; s x y z = x z (y z); k x y = x; main_ = id 3")
    , ("3", "id = s k k; s x y z = x z (y z); k x y = x; twice f x = f (f x);"
      ++ "main_ = twice twice twice id 3")
    , ("3", "i x = x; twice f x = f (f x ); main_ = twice (i i i) 3")
    , ("4", concat
      [ "cons a b cc cn = cc a b; nil cc cn = cn; hd list = list k abort;"
      , "abort = abort;"
      , "k x y = x; k1 x y = y;"
      , "tl list = list k1 abort;"
      -- The following fail to type-check:
      --   infinite x = cons x (infinite x);
      -- so we make do with a fixed list.
      , "main_ = hd (tl (cons 3 (cons 4 nil)))"
      ])
    , ("17", "main_ = 4*5+(2-5)")
    , ("8", "twice f x = f (f x); inc x = x + 1; main_ = twice twice inc 4")
      -- Change list representation so that `length` can be typed.
    , ("3", concat
      [ "length xs = xs (\\h a -> 1 + a) 0;"
      , "cons h t c n = c h(t c n); nil c n = n;"
      , "main_ = length (cons 3 (cons 3 (cons 3 nil)))"
      ])
    , ("120", "fac n = case n == 0 of { True -> 1; False -> (n * fac (n - 1)) }\nmain_ = fac 5")
    , ("2", "gcd a b = case a == b of { True -> a; False -> case a < b of"
      ++ " { True -> gcd b a; False -> gcd b (a - b) } }; main_ = gcd 6 10")
    , ("9", "nfib n = case n < 2 of { True -> 1; False -> 1 + nfib (n - 1) + nfib (n - 2) }; main_ = nfib 4")
    , ("Pack 1", "main_ = 2 + 2 == 4")
    , ("Pack 0", "main_ = 2 + 2 == 5")
    , ("Pack 1", "main_ = [1,1,2] == [1,1,2]")
    , ("Pack 1", "main_ = [[1,1],[2]] == [[1,1],[2]]")
    , ("Pack 0", "main_ = [[1],[2]]   == [[1,1],[2]]")
    , ("Pack 0", "main_ = (==) [[1,1],[2]] [[1,3],[2]]")
    , ("Pack 1", "f x = x == x; main_ = f [1,2,3]")
    , (show ["hello"], "main = putHello")
    , (show ["hello", "hello"], "main = putHello >>= (\\x -> putHello)")
    ]