# This code is derived from the Savina benchmark suite,
# maintained at https://github.com/shamsmahmood/savina.
# This benchmark is a Ruby version of the Scala benchmark
# "ApspAkkaActorBenchmark.scala" in that repository.
# The LICENSE is GPLv2 as the original benchmark:
# http://www.gnu.org/licenses/old-licenses/gpl-2.0.en.html

# Savina All-Pairs Shortest Path

#ARGS = [180, 30, 100]
#ARGS = [90, 30, 100] # Too short
#ARGS = [180, 60, 100] # 9 actors + main
ARGS = [180, 90, 100] # 4 actors

require_relative 'savina-common'

NUM_WORKERS, BLOCK_SIZE, MAX_EDGE_WEIGHT = ARGS

raise "bad params"  unless NUM_WORKERS % BLOCK_SIZE == 0
NUM_BLOCKS_IN_SINGLE_DIM = NUM_WORKERS / BLOCK_SIZE
NUM_BLOCKS = NUM_BLOCKS_IN_SINGLE_DIM * NUM_BLOCKS_IN_SINGLE_DIM

NeighborMessage = Struct.new(:neighbors)
InitialMessage = :initial
ResultMessage = Struct.new(:k, :myBlockId, :initData)

class Matrix
  def initialize(n)
    @n = n
    @data = Array.new(n*n) { |k|
      i = k / n
      j = k % n
      yield(i,j)
    }
    freeze
  end

  def [](i,j)
    @data[i*@n+j]
  end
end

module ApspUtils
  def self.generateGraph
    random = MyRandom.new(NUM_WORKERS)
    Matrix.new(NUM_WORKERS) { |i,j|
      if j == i
        0
      else
        random.nextInt(MAX_EDGE_WEIGHT)
      end
    }
  end

  GRAPH_DATA = generateGraph

  def self.getBlock(myBlockId)
    globalStartRow = (myBlockId / NUM_BLOCKS_IN_SINGLE_DIM) * BLOCK_SIZE
    globalStartCol = (myBlockId % NUM_BLOCKS_IN_SINGLE_DIM) * BLOCK_SIZE
    Matrix.new(BLOCK_SIZE) { |i,j|
      GRAPH_DATA[globalStartRow + i, globalStartCol + j]
    }
  end

  def self.solve(graph)
    # Floyd-Warshall
    dist = Array.new(NUM_WORKERS) { |i|
      Array.new(NUM_WORKERS) { |j|
        GRAPH_DATA[i,j]
      }
    }
    NUM_WORKERS.times { |k|
      NUM_WORKERS.times { |i|
        NUM_WORKERS.times { |j|
          if dist[i][j] > dist[i][k] + dist[k][j]
            dist[i][j] = dist[i][k] + dist[k][j]
          end
        }
      }
    }
    dist
  end

  SOLUTION = solve(GRAPH_DATA)
end

class SavinaApsp < Benchmark
  def benchmark
    blockActors = Array.new(NUM_BLOCKS_IN_SINGLE_DIM) { |i|
      Array.new(NUM_BLOCKS_IN_SINGLE_DIM) { |j|
        myBlockId = i * NUM_BLOCKS_IN_SINGLE_DIM + j
        FloydWarshallActor.new(myBlockId)
      }
    }

    # create the links to the neighbors
    NUM_BLOCKS_IN_SINGLE_DIM.times { |i|
      NUM_BLOCKS_IN_SINGLE_DIM.times { |j|
        current = blockActors[i][j]
        neighbors = (blockActors.map { |row| row[j] } + blockActors[i])
        neighbors.delete current
        current.send! NeighborMessage.new(neighbors.freeze)
      }
    }

    # start the computation
    blockActors.each { |row| row.each { |actor| actor.send! InitialMessage } }

    Actor.await_all_actors

    blockActors
  end

  def self.verify(blockActors)
    result = Array.new(NUM_WORKERS) { Array.new(NUM_WORKERS, -1) }
    blockActors.each { |row|
      row.each { |actor|
        BLOCK_SIZE.times { |i|
          BLOCK_SIZE.times { |j|
            result[actor.row_offset+i][actor.col_offset + j] = actor.currentIterData[i,j]
          }
        }
      }
    }
    unless result == ApspUtils::SOLUTION
      puts ApspUtils::SOLUTION.map(&:to_s)
      puts
      puts result.map(&:to_s)
      raise "Wrong result"
    end
    true
  end
end

class FloydWarshallActor < Actor
  NUM_NEIGHBORS = 2 * (NUM_BLOCKS_IN_SINGLE_DIM - 1)

  attr_reader :currentIterData, :row_offset, :col_offset

  def initialize(myBlockId)
    @myBlockId = myBlockId
    @row_offset = (myBlockId / NUM_BLOCKS_IN_SINGLE_DIM) * BLOCK_SIZE
    @col_offset = (myBlockId % NUM_BLOCKS_IN_SINGLE_DIM) * BLOCK_SIZE
    @k = -1
    @neighborDataPerIteration = Array.new(NUM_BLOCKS, nil)
    @received = 0
    @currentIterData = ApspUtils.getBlock(myBlockId)
  end

  def process(message)
    case message
    when NeighborMessage
      @neighbors = message.neighbors
    when InitialMessage
      notifyNeighbors
    when ResultMessage
      raise unless @neighbors.size == NUM_NEIGHBORS
      haveAllData = storeIterationData(message.k, message.myBlockId, message.initData)
      if haveAllData
        # received enough data from neighbors, can proceed to do computation for next k
        @k += 1

        performComputation
        notifyNeighbors
        @neighborDataPerIteration.fill(nil)
        @received = 0

        if @k == NUM_WORKERS - 1
          # we've completed the computation
          :exit
        end
      end
    end
  end

  def storeIterationData(iteration, sourceId, dataArray)
    #raise [iteration,@k].inspect unless iteration == @k or iteration == -1
    @received += 1 unless @neighborDataPerIteration[sourceId]
    @neighborDataPerIteration[sourceId] = dataArray
    @received == NUM_NEIGHBORS
  end

  def performComputation
    prevIterData = @currentIterData
    # make modifications on a fresh local data array for this iteration
    @currentIterData = Matrix.new(BLOCK_SIZE) { |i,j|
      gi = @row_offset + i
      gj = @col_offset + j
      newIterData = elementAt(gi, @k, prevIterData) + elementAt(@k, gj, prevIterData)
      [prevIterData[i,j], newIterData].min
    }
  end

  def elementAt(row, col, prevIterData)
    destBlockId = (row / BLOCK_SIZE) * NUM_BLOCKS_IN_SINGLE_DIM + col / BLOCK_SIZE
    localRow = row % BLOCK_SIZE
    localCol = col % BLOCK_SIZE

    # puts "Accessing block-#{destBlockId} from block-#{@myBlockId} for (#{row}, #{col})"

    if destBlockId == @myBlockId
      prevIterData[localRow,localCol]
    else
      @neighborDataPerIteration[destBlockId][localRow,localCol]
    end
  end

  def notifyNeighbors
    # send the current result to all other blocks who might need it
    # note: this is inefficient version where data is sent to neighbors
    # who might not need it for the current value of k
    resultMessage = ResultMessage.new(@k, @myBlockId, @currentIterData)
    @neighbors.each { |neighbor| neighbor.send!(resultMessage) }
  end
end
