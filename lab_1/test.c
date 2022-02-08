#include <stdlib.h>
#include <stdio.h>
#include <math.h>

int main()
{
	int n_sin = 10000000;
	double *sins = (double*)malloc(sizeof(double) * n_sin);

	double sum_sin = 0;

#pragma acc kernels
{
	for (int i = 0; i < n_sin + 1; i++)
	{
		sins[i] = sin(2 * M_PI / (double)i);
	}

	for (int i =0; i < n_sin + 1; i++)
	{
		sum_sin += sins[i];
	}
}

	printf("%lf\n", sum_sin);

	return 0;
}


