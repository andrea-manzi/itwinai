#!/bin/bash

# Job configuration
#SBATCH --job-name=ray_tune_hpo
#SBATCH --account=intertwin
#SBATCH --time 01:00:00

# Resources allocation
#SBATCH --cpus-per-task=8
#SBATCH --nodes=1
#SBATCH --ntasks-per-node=1
#SBATCH --gpus-per-node=4
#SBATCH --partition=develbooster
#SBATCH --exclusive

# Output and error logs
#SBATCH -o job.out
#SBATCH -e job.err

# Load environment modules
ml Stages/2024 GCC OpenMPI CUDA/12 MPI-settings/CUDA Python HDF5 PnetCDF libaio mpi4py

# Set and activate virtual environment
PYTHON_VENV="itwinai/envAI_juwels"
source $PYTHON_VENV/bin/activate

# make sure CUDA devices are visible
export CUDA_VISIBLE_DEVICES="0,1,2,3"

num_gpus=$SLURM_GPUS_PER_NODE
num_cpus=$SLURM_CPUS_PER_TASK

# This tells Tune to not change the working directory to the trial directory
# which makes relative paths accessible from inside a trial
export RAY_CHDIR_TO_TRIAL_DIR=0
export RAY_DEDUP_LOGS=0
export RAY_USAGE_STATS_DISABLE=1

#########   Set up Ray cluster   ########

# Get the node names
nodes=$(scontrol show hostnames "$SLURM_JOB_NODELIST")
nodes_array=($nodes)

# The head node will act as the central manager (head) of the Ray cluster.
head_node=${nodes_array[0]}
port=7639       # This port will be used by Ray to communicate with worker nodes.

echo "Starting HEAD at $head_node"
# Start Ray on the head node.
# The `--head` option specifies that this node will be the head of the Ray cluster.
# `srun` submits a job that runs on the head node to start the Ray head with the specified
# number of CPUs and GPUs.
srun --nodes=1 --ntasks=1 -w "$head_node" \
    ray start --head --node-ip-address="$head_node"i --port=$port \
    --num-cpus "$num_cpus" --num-gpus "$num_gpus"  --block &

# Wait for a few seconds to ensure that the head node has fully initialized.
sleep 10

echo HEAD node started.

# Start Ray worker nodes
# These nodes will connect to the head node and become part of the Ray cluster.
worker_num=$((SLURM_JOB_NUM_NODES - 1))    # Total number of worker nodes (excluding the head node).
for ((i = 1; i <= worker_num; i++)); do
    node_i=${nodes_array[$i]}   # Get the current worker node hostname.
    echo "Starting WORKER $i at $node_i"

    # Use srun to start Ray on the worker node and connect it to the head node.
    # The `--address` option tells the worker node where to find the head node.
    srun \
    --nodes=1 \
    --ntasks=1 \
    -w "$node_i" \
    ray start \
    --address "$head_node":"$port" \
    --redis-password='5241580000000000' \
    --num-cpus "$num_cpus" \
    --num-gpus "$num_gpus" \
    --block &

    sleep 5 # Wait for a few seconds before starting the next worker to prevent race conditions.
done
echo All Ray workers started.

##############################################################################################


# Run the Python script using Ray
echo 'Starting HPO.'

python hpo.py --num_samples 8 --max_iterations 2 --ngpus $num_gpus --ncpus $num_cpus --pipeline_name pipeline

# Shutdown Ray after completion
ray stop
