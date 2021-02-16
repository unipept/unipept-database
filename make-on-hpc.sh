#!/bin/sh
#PBS -N unipept-backend
#PBS -m abe
#PBS -l nodes=1:ppn=24
#PBS -l walltime=72:00:00
#PBS -l vmem=480gb

# Running:
# $ module swap cluster/kirlia
# $ qsub make-on-hpc.sh

# Loading the required modules
module load Java
module load Maven

# Check the current directory
pushd "$PBS_O_WORKDIR"

# Running the makefile
./run.sh database

# Reset the directory
popd

