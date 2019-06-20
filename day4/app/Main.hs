{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE DeriveGeneric               #-}

-- | = Batch normalization demo

import           Data.Massiv.Array hiding ( map, zip, unzip )
import qualified Data.Massiv.Array as A
import qualified Data.Massiv.Array.Manifest.Vector as A
import           Streamly
import qualified Streamly.Prelude as S
import           Text.Printf ( printf )
import           Control.DeepSeq ( force )
import           Control.Monad.Trans.Maybe
import           Data.IDX
import qualified Data.Vector.Unboxed as V
import           Data.List.Split ( chunksOf )
import           Numeric.Backprop
import           Lens.Micro.TH
import           GHC.Generics ( Generic )

import           NeuralNetwork
import           Shuffle ( shuffleIO )

data Net = Net { _w1 :: Matrix Float
               , _b1 :: Vector Float
               , _w2 :: Matrix Float
               , _b2 :: Vector Float
               , _w3 :: Matrix Float
               , _b3 :: Vector Float
               }
  deriving (Show, Generic)

instance Backprop Net

makeLenses ''Net

forward
  :: Reifies s W =>
     BVar s Net -> BVar s (Matrix Float) -> BVar s (Matrix Float)
forward net x = linear z (net ^^. w3, net ^^. b3)
  where
    -- First layer
    y = relu_ $ linear x (net ^^. w1, net ^^. b1)
    -- Second layer
    z = relu_ $ linear y (net ^^. w2, net ^^. b2)

loadMNIST
  :: FilePath -> FilePath -> IO (Maybe [(Matrix Float, Matrix Float)])
loadMNIST fpI fpL = runMaybeT $ do
    i <- MaybeT $ decodeIDXFile fpI
    l <- MaybeT $ decodeIDXLabelsFile fpL
    d <- MaybeT. return $ force $ labeledIntData l i
    r <- return $ map _conv d
    return r
  where
    _conv :: (Int, V.Vector Int) -> (Matrix Float, Matrix Float)
    _conv (label, v) = (v1, toOneHot10 label)
      where
        v0 = V.map ((`subtract` 0.5). (/ 255). fromIntegral) v
        v1 = A.fromVector' Par (Sz2 1 784) v0

toOneHot10 :: Int -> Matrix Float
toOneHot10 n = A.makeArrayR U Par (Sz2 1 10) (\(_ :. j) -> if j == n then 1 else 0)

mnistStream
  :: Int -> FilePath -> FilePath
  -> IO (SerialT IO (Matrix Float, Matrix Float))
mnistStream batchSize fpI fpL = do
  Just dta <- loadMNIST fpI fpL
  dta2 <- shuffleIO dta

  -- Split data into batches
  let (vs, labs) = unzip dta2
      merge :: [Matrix Float] -> Matrix Float
      merge = A.compute. A.concat' 2
      vs' = map merge $ chunksOf batchSize vs
      labs' = map merge $ chunksOf batchSize labs
      dta' = zip vs' labs'
  return $ S.fromList dta'

main :: IO ()
main = do
  trainS <- mnistStream 1000 "data/train-images-idx3-ubyte" "data/train-labels-idx1-ubyte"
  testS <- mnistStream 1000 "data/t10k-images-idx3-ubyte" "data/t10k-labels-idx1-ubyte"

  let [i, h1, h2, o] = [784, 300, 50, 10]
  (w1_, b1_) <- genWeights (i, h1)
  let ones n = A.replicate Par (Sz1 n) 1 :: Vector Float
      zeros n = A.replicate Par (Sz1 n) 0 :: Vector Float
  (w2_, b2_) <- genWeights (h1, h2)
  (w3_, b3_) <- genWeights (h2, o)

  let net = Net { _w1 = w1_
                , _b1 = b1_
                , _w2 = w2_
                , _b2 = b2_
                , _w3 = w3_
                , _b3 = b3_
                }

  return ()

  {-
  -- With batchnorm
  -- NB: Layer' has only weights, no biases.
  -- The reason is that Batchnorm1d layer has trainable
  -- parameter beta performing similar transformation.
  let net = [ Linear' w1
            , Batchnorm1d (zeros h1) (ones h1) (ones h1) (zeros h1)
            , Activation Relu
            , Linear' w2
            , Batchnorm1d (zeros h2) (ones h2) (ones h2) (zeros h2)
            , Activation Relu
            , Linear' w3
            ]

  -- No batchnorm layer
  let net2 = [ Linear w1 b1
             , Activation Relu
             , Linear w2 b2
             , Activation Relu
             , Linear w3 b3
             ]

  -- Crucial parameters: initial weights magnitude and
  -- learning rate (lr)
  let epochs = 10
      lr = 0.1

  net' <- sgd lr epochs net trainS
  net2' <- sgd lr epochs net2 trainS

  putStrLn $ printf "%d training epochs" epochs

  tacc <- net' `avgAccuracy` trainS
  putStrLn $ printf "Training accuracy (SGD + batchnorm) %.1f" tacc

  acc <- net' `avgAccuracy` testS
  putStrLn $ printf "Validation accuracy (SGD + batchnorm) %.1f" acc

  tacc2 <- net2' `avgAccuracy` trainS
  putStrLn $ printf "Training accuracy (SGD) %.1f" tacc2

  acc2 <- net2' `avgAccuracy` testS
  putStrLn $ printf "Validation accuracy (SGD) %.1f" acc2
  -}
