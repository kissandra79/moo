{-# Language BangPatterns #-}

{- |
Copyright    : 2010-2011 Erlend Hamberg, 2011 Sergey Astanin
License      : BSD3
Stability    : experimental
Portability  : portable

A framework for simple genetic algorithms.

First a random number generator needs to be obtained with 'newPureMT',
then use 'runRandom' or 'evalRandom' to run simulation in the 'Rand'
monad.  'nextGeneration' implements a single iteration of the
algorithm, 'iterateM' and 'iterateUntilM' allow to repeat it as long
as necessary.  The user has to provide an initial population, genome's
fitness function, selection, crossover and mutation operators.
See an example below.

"AI.SimpleEA.Utils" module contains utilitify functions that implement
some most common types of genetic operators: selection, mutation,
crossover.

"AI.SimpleEA.Rand" module provides some additional facilities to make
'PureMT' random number generator as convenient as the standard
generator.

-}

module AI.SimpleEA (
  -- * Running algorithm
    runGA
  , nextGeneration
  , evalFitness
  , iterateM
  , iterateUntilM
  , iterateHistoryM
  -- * Types
  , FitnessFunction
  , SelectionOp
  , CrossoverOp
  , MutationOp
  , Fitness
  , Genome
  -- * Example Program
  -- $SimpleEAExample
) where

import Control.Monad.Mersenne.Random
import System.Random.Mersenne.Pure64 (newPureMT)

type Fitness = Double
type Genome a = [a]  -- TODO: allow for efficient bit-vectors/custom types

-- | A fitness functions assigns a fitness score to a genome. The rest of the
-- individuals of that generation is also provided in case the fitness is
-- in proportion to its neighbours. Genetic algorithm maximizes the fitness.
--
-- Some genetic algorithm operators, like 'rouletteSelect', require
-- non-negative fitness.  To solve minimization problems consider
-- transforming the fitness value as @F(x) = 1/(1+f(x))@ or
-- @F(x) = LargePositive - objective(x)/mean(objective(x_i))@.
type FitnessFunction a       = Genome a -> [Genome a] -> Fitness

-- | A selection operator is responsible for selection. It takes pairs of
-- genomes and their fitness and is responsible for returning one or more
-- individuals.
type SelectionOp a = [(Genome a, Fitness)] -> Rand [Genome a]

-- | A recombination operator takes two /parent/ genomes and returns two
-- /children/.
type CrossoverOp a = (Genome a, Genome a) -> Rand (Genome a, Genome a)

-- | A mutation operator takes a genome and returns an altered copy of it.
type MutationOp a        = Genome a -> Rand (Genome a)

-- | Helper function to run an entire algorithm in the 'Rand' monad.
-- It takes care of generating a new random number generator.
runGA :: Rand a -> IO a
runGA ga = do
  rng <- newPureMT
  return $ evalRandom ga rng

-- | A single step of the genetic algorithm. Take a population with
-- evaluated fitness values (@pop@), select according to @selFun@,
-- produce offspring population through crossover (@recOp@) and
-- mutation (@mutOp@), evaluate new fitness values.
--
-- "AI.SimpleEA.Utils" provides some operators which may be used as
-- building blocks of the algorithm.
-- Initialization: 'getRandomGenomes'.
-- Selection: 'rouletteSelect', 'tournamentSelect'.
-- Crossover: 'onePointCrossover', 'twoPointCrossover', 'uniformCrossover'.
-- Mutation: 'uniformMutate'.
nextGeneration ::
    FitnessFunction a ->
    SelectionOp a ->
    CrossoverOp a ->
    MutationOp a ->
    [(Genome a, Fitness)] ->
    Rand [(Genome a, Fitness)]
nextGeneration fitFun selFun recOp mutOp pop = do
  genomes <- selFun pop
  -- TODO: shuffle?
  genomes <- doCrossovers genomes recOp
  genomes <- mapM mutOp genomes
  return $ evalFitness fitFun genomes

-- | Evaluate fitness for all genomes in the population.
evalFitness :: FitnessFunction a -> [Genome a] -> [(Genome a, Fitness)]
evalFitness fitFun gs =
  let fs = map (`fitFun` gs) gs
  in  zip gs fs

doCrossovers :: [Genome a] -> CrossoverOp a -> Rand [Genome a]
doCrossovers []      _   = return []
doCrossovers [_]     _   = error "odd number of parents"
doCrossovers (a:b:r) rec = do
    (a',b') <- rec (a,b)
    rest    <- doCrossovers r rec
    return $ a':b':rest

-- | Run @n@ strict iterations of monadic action @step@. Return the result
-- of the last step.
{-# INLINE iterateM #-}
iterateM :: (Monad m) => Int -> (a -> m a) -> a -> m a
iterateM n step x = go n x
    where
      go 0 !x = return x
      go n !x = step x >>= go (n-1)

-- | Run strict iteration of monadic action @step@ until termination
-- condition @termCond@ is True. Return the result of the last step.
{-# INLINE iterateUntilM #-}
iterateUntilM :: (Monad m) => (a -> Bool) ->  (a ->  m a) ->  a ->  m a
iterateUntilM termCond step x = go x
    where
      go !x | termCond x = return x
            | otherwise = step x >>= go

-- | Like 'iterateM', but return the reversed history of the intermediate
-- results (the last result in the head of the list).
-- TODO: rewrite with MonadWriter.
{-# INLINE iterateHistoryM #-}
iterateHistoryM :: (Monad m) => Int -> (a -> m a) -> a -> m [a]
iterateHistoryM n step x = go n x []
    where
      go 0 !x !a = return (x:a)
      go n !x !a = step x >>= \x' -> go (n-1) x' (x':a)

{- $SimpleEAExample

The aim of this /OneMax/ EA is to maximize the number of @1@'s in a
bitstring.  The fitness of a bitstring i simply s defined to be the
number of @1@'s it contains.

>import AI.SimpleEA
>import AI.SimpleEA.Utils
>import AI.SimpleEA.Rand
>
>import Control.Monad.Mersenne.Random
>import System.Random.Mersenne.Pure64
>import Data.List
>import System.Environment (getArgs)
>import Control.Monad (unless, liftM, replicateM)

The @numOnes@ function will function as our 'FitnessFunction' and simply
returns the number of @1@'s in the string.

>numOnes :: FitnessFunction Char
>numOnes g _ = (fromIntegral . length . filter (=='1')) g

The @select@ function is our 'SelectionOp'. It uses
sigma-scaled, fitness-proportionate selection. 'sigmaScale' is defined
in 'SimpleEA.Utils'. By first taking the four best genomes (by using
the 'elite' function) we get elitism, making sure that maximum fitness
never decreases.

>select :: SelectionOp Char
>select gs = select' (take 4 $ elite gs)
>    where scaled = zip (map fst gs) (sigmaScale (map snd gs))
>          select' gs' =
>              let n = 2 * (length gs `div` 2 + 1) -- n >= length gs, n is even
>              in  replicateM n (rouletteSelect scaled)

Mutation flips a random bit along the length of the genome with
probability @p@.

>mutate :: Double -> MutationOp Char
>mutate p g = do
>    t <- getDouble
>    if t < p
>       then do
>           r <- getIntR (0, length g-1)
>           return (take r g ++ flipBit (g !! r) : drop (r+1) g)
>       else return g
>        where
>              flipBit '0' = '1'
>              flipBit '1' = '0'

The @main@ function creates a list of 100 random genomes (bit-strings)
of length 20 and then runs the EA for 41 generations (42 generations
including the random starting population). Average and maximum fitness
values and standard deviation is then calculated for each generation
and written to a file if a file name was provided as a parameter. This
data can then be plotted with, e.g.  gnuplot
(<http://www.gnuplot.info/>).

>main = do
>    args <- getArgs
>    gs <- runGA $ do
>       initialGs <- getRandomGenomes 100 20 ('0', '1')
>       let pop = evalFitness numOnes initialGs
>       let xover = onePointCrossover 0.33
>       let step = nextGeneration numOnes select xover (mutate 0.01)
>       reverse `liftM` iterateHistoryM 41 step pop
>    let fs = map avgFitness gs
>    let ms = map maxFitness gs
>    let ds = map stdDeviation gs
>    let gen_avg_best_std = getPlottingData gs
>    if (null args)
>      then putStr gen_avg_best_std
>      else writeFile (head args) gen_avg_best_std

-}
