#include <stdio.h>
#include <stdlib.h>
#include <cuda_runtime.h>
#include <cub/cub.cuh>

#define BLOCK_DIM 16

#define CUDACHKERR(err) if (err != cudaSuccess) { \
    fprintf(stderr, \
            "Failed to copy vector B from host to device (error code %s)!\n", \
            cudaGetErrorString(err)); \
    exit(EXIT_FAILURE); \
  }

void print_help()
{
	printf("usage:\n");
	printf("{min_error} {matrix_size} {iter_max}\n");
}

double* getSetMatrix(double* dst, int size)
{
    cudaError_t err;

	double *matrix;
    err = cudaMalloc(&matrix, size * size * sizeof(double));
    CUDACHKERR(err);

    err = cudaMemcpy(matrix, dst, size * size * sizeof(double), cudaMemcpyHostToDevice);
    CUDACHKERR(err);

	return matrix;
}

void interpolationMatrixSides(double* matrix, int matrix_size)
{
	// left side
	for (int i = 1; i < matrix_size - 1; ++i)
	{
		matrix[i * matrix_size] = matrix[0] * (matrix_size - 1 - i) / (matrix_size - 1) +
					   			  matrix[matrix_size * (matrix_size - 1)] * i / (matrix_size - 1);
	}

	// top side
	for (int i = 1; i < matrix_size - 1; ++i)
	{
		matrix[i] = matrix[0] * (matrix_size - 1 - i) / (matrix_size - 1) +
					matrix[matrix_size - 1] * i / (matrix_size - 1);
	}

	// right side
	for (int i = 1; i < matrix_size - 1; ++i)
	{
		matrix[i * matrix_size + matrix_size - 1] = matrix[matrix_size - 1] * (matrix_size - 1 - i) / (matrix_size - 1) +
					   				 				matrix[(matrix_size - 1) * matrix_size + matrix_size - 1] * i / (matrix_size - 1);
	}

	// bottom side
	for (int i = 1; i < matrix_size - 1; ++i)
	{
		matrix[(matrix_size - 1) * matrix_size + i] = matrix[(matrix_size - 1) * matrix_size] * (matrix_size - 1 - i) / (matrix_size - 1) +
					                 				  matrix[(matrix_size - 1) * matrix_size + matrix_size - 1] * i / (matrix_size - 1);
	}
}

__global__ void vecNeg(const double *newA, const double *A, double* ans, int numElements)
{
    int idx = blockIdx.x * blockDim.x + threadIdx.x;

    if (idx < numElements)
    {
        ans[idx] =  newA[idx] - A[idx];
    }
}

__global__ void evalEquation(double *newA, const double *A, int numElements)
{
    __shared__ double temp[BLOCK_DIM + 2][BLOCK_DIM + 2];

    int idx = blockIdx.x * blockDim.x + threadIdx.x;
    int idy = blockIdx.y * blockDim.y + threadIdx.y;

    if (idx < numElements && idy < numElements)
    {
    	temp[threadIdx.y + 1][threadIdx.x + 1] = A[idy * numElements + idx];

        if (threadIdx.x == (BLOCK_DIM - 1))
        {
            temp[threadIdx.y + 1][threadIdx.x + 2] = A[idy * numElements + idx + 1];
        }

        if (threadIdx.x == 0)
        {
            temp[threadIdx.y + 1][threadIdx.x] = A[idy * numElements + idx - 1];
        }

        if (threadIdx.y == (BLOCK_DIM - 1))
        {
            temp[threadIdx.y + 2][threadIdx.x + 1] = A[(idy + 1) * numElements + idx];
        }

        if (threadIdx.y == 0)
        {
            temp[threadIdx.y][threadIdx.x + 1] = A[(idy - 1) * numElements + idx];
        }
    }

    __syncthreads();

    if ((0 < idx && idx < numElements - 1) && (0 < idy && idy < numElements - 1))
    {
        newA[idy * numElements + idx] = 0.25 * (temp[threadIdx.y + 2][threadIdx.x + 1] + temp[threadIdx.y + 1][threadIdx.x] +
											    temp[threadIdx.y][threadIdx.x + 1] + temp[threadIdx.y + 1][threadIdx.x + 2]);
    }
}

void printCudaMatrix(double* dst, int size)
{
    double *a = (double*)calloc(sizeof(double), size * size);

    cudaMemcpy(a, dst, size * size * sizeof(double), cudaMemcpyDeviceToHost);

    for (int i = 0; i < size; ++i)
	{
		for (int j = 0; j < size; ++j)
		{
			printf("%lf ", a[i * size + j]);
		}
		printf("\n");
	}
    printf("\n");
}

int main(int argc, char *argv[])
{
    if (argc == 1)
	{
		print_help();
		exit(0);
	}

	double min_error = atof(argv[1]);
	int matrix_size = atoi(argv[2]);
	int iter_max = atoi(argv[3]);

    cudaError_t err;

    double *tmp = (double*)calloc(sizeof(double), matrix_size * matrix_size);

    tmp[0] = 10.0;
	tmp[matrix_size - 1] = 20.0;
	tmp[(matrix_size - 1) * matrix_size] = 20.0;
	tmp[(matrix_size - 1) * matrix_size + matrix_size - 1] = 30.0;

    interpolationMatrixSides(tmp, matrix_size);

    double *A_d = getSetMatrix(tmp, matrix_size);
	double *newA_d = getSetMatrix(tmp, matrix_size);
    free(tmp);

    int iter = 0;
	double error = 10;

    dim3 BS = dim3(BLOCK_DIM, BLOCK_DIM);
    dim3 GS = dim3(ceil(matrix_size / (double)BS.x), ceil(matrix_size / (double)BS.y));

    void *d_temp_storage = NULL;
    size_t temp_storage_bytes = 0;

    double *tmp_d, *max_d;
    cudaMalloc(&tmp_d, sizeof(double) * matrix_size * matrix_size);
    cudaMalloc(&max_d, sizeof(double));

    cub::DeviceReduce::Max(d_temp_storage, temp_storage_bytes, tmp_d, max_d, matrix_size * matrix_size);
    cudaMalloc(&d_temp_storage, temp_storage_bytes);

    int BS_neg = matrix_size;
    int GS_neg = ceil(matrix_size * matrix_size / (double)BS_neg);

    while (error > min_error && iter < iter_max)
    {
        ++iter;
        if (iter % 100 == 0)
		{
			printf("iter = %d error = %e\n", iter, error);
			error = 0;

            evalEquation<<<GS, BS>>>(newA_d, A_d, matrix_size);

            // printCudaMatrix(newA_d, matrix_size);

            vecNeg<<<GS_neg, BS_neg>>>(newA_d, A_d, tmp_d, matrix_size * matrix_size);
            err = cub::DeviceReduce::Max(d_temp_storage, temp_storage_bytes, tmp_d, max_d, matrix_size * matrix_size);
            CUDACHKERR(err);

            // printf("1\n");

            err = cudaMemcpy(&error, max_d, sizeof(double), cudaMemcpyDeviceToHost);
            CUDACHKERR(err);

            // printf("2\n");
        }
        else
        {
            // printCudaMatrix(newA_d, matrix_size);
            evalEquation<<<GS, BS>>>(newA_d, A_d, matrix_size);
            // printCudaMatrix(newA_d, matrix_size);

        }

        double *tmp = A_d;
		A_d = newA_d;
		newA_d = tmp;
    }

    cudaFree(A_d);
    cudaFree(newA_d);
    cudaFree(tmp_d);
    cudaFree(max_d);
    cudaFree(d_temp_storage);

    return 0;
}
