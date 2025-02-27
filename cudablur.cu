//Simple optimized box blur
//by: Theodore O'Neill and Adheena Chacko
//Date: 5/14/2021
//This program reads an image and performs a simple averaging of pixels within a supplied radius.  For optimization,
//it does this by computing a running sum for each column within the radius, then averaging that sum.  Then the same for
//each row.  This should allow it to be easily parallelized by column then by row, since each call is independent.

#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <time.h>
#define STB_IMAGE_IMPLEMENTATION
#include "stb_image.h"

#define STB_IMAGE_WRITE_IMPLEMENTATION
#include "stb_image_write.h"

//Computes a single row of the destination image by summing radius pixels
//Parameters: src: Teh src image as width*height*bpp 1d array
//            dest: pre-allocated array of size width*height*bpp to receive summed row
//            row: The current row number
//            pWidth: The width of the image * the bpp (i.e. number of bytes in a row)
//            rad: the width of the blur
//            bpp: The bits per pixel in the src image
//            height: the height of the source image
//Returns: None

__global__ void computeRow(float *src, float *dest, int pWidth, int radius, int bpp, int height)
{
    int i;
   int row = threadIdx.x + (blockIdx.x * blockDim.x);

    int bradius = radius * bpp;

    if (height > row)
    {
        //initialize the first bpp elements so that nothing fails
        for (i = 0; i < bpp; i++)
            dest[row * pWidth + i] = src[row * pWidth + i];
        //start the sum up to radius*2 by only adding (nothing to subtract yet)
        for (i = bpp; i < bradius * 2 * bpp; i++)
            dest[row * pWidth + i] = src[row * pWidth + i] + dest[row * pWidth + i - bpp];

        for (i = bradius * 2 + bpp; i < pWidth; i++)
            dest[row * pWidth + i] = src[row * pWidth + i] + dest[row * pWidth + i - bpp] - src[row * pWidth + i - 2 * bradius - bpp];
        //now shift everything over by radius spaces and blank out the last radius items to account for sums at the end of the kernel, instead of the middle
        for (i = bradius; i < pWidth; i++)
        {
            dest[row * pWidth + i - bradius] = dest[row * pWidth + i] / (radius * 2 + 1);
        }
        //now the first and last radius values make no sense, so blank them out
        for (i = 0; i < bradius; i++)
        {
            dest[row * pWidth + i] = 0;
            dest[(row + 1) * pWidth - 1 - i] = 0;
        }
    }
}

//Computes a single column of the destination image by summing radius pixels
//Parameters: src: Teh src image as width*height*bpp 1d array
//            dest: pre-allocated array of size width*height*bpp to receive summed row
//            col: The current column number
//            pWidth: The width of the image * the bpp (i.e. number of bytes in a row)
//            height: The height of the source image
//            radius: the width of the blur
//            bpp: The bits per pixel in the src image
//Returns: None
__global__ void computeColumn(uint8_t *src, float *dest, int pWidth, int height, int radius, int bpp)
{
    int i;
    int col = threadIdx.x + (blockIdx.x * blockDim.x);

    if (pWidth > col)
    {
        //initialize the first element of each column
        dest[col] = src[col];
        //start tue sum up to radius*2 by only adding
        for (i = 1; i <= radius * 2; i++)
            dest[i * pWidth + col] = src[i * pWidth + col] + dest[(i - 1) * pWidth + col];
        for (i = radius * 2 + 1; i < height; i++)
            dest[i * pWidth + col] = src[i * pWidth + col] + dest[(i - 1) * pWidth + col] - src[(i - 2 * radius - 1) * pWidth + col];
        //now shift everything up by radius spaces and blank out the last radius items to account for sums at the end of the kernel, instead of the middle
        for (i = radius; i < height; i++)
        {
            dest[(i - radius) * pWidth + col] = dest[i * pWidth + col] / (radius * 2 + 1);
        }
        //now the first and last radius values make no sense, so blank them out
        for (i = 0; i < radius; i++)
        {
            dest[i * pWidth + col] = 0;
            dest[(height - 1) * pWidth - i * pWidth + col] = 0;
        }
    }
}

//Usage: Prints the usage for this program
//Parameters: name: The name of the program
//Returns: Always returns -1
int Usage(char *name)
{
    printf("%s: <filename> <blur radius>\n\tblur radius=pixels to average on any side of the current pixel\n", name);
    return -1;
}

int main(int argc, char **argv)
{
    double t1, t2;
    int radius = 0;
    int i;
    int width, height, bpp, pWidth;
    char *filename;
    uint8_t *img;
    float *dest, *mid;
    uint8_t *dest_img;

    if (argc != 3)
        return Usage(argv[0]);
    filename = argv[1];
    sscanf(argv[2], "%d", &radius);

    //sourc image
    img = stbi_load(filename, &width, &height, &bpp, 0);

    pWidth = width * bpp; //actual width in bytes of an image row

    //mid = malloc(sizeof(float) * pWidth * height);
    //dest = malloc(sizeof(float) * pWidth * height);
    //cudaMallocManaged(&img, sizeof(uint8_t) * pWidth * height);

    cudaMalloc(&dest_img, sizeof(uint8_t) * pWidth * height);
    cudaMallocManaged(&mid, sizeof(float) * pWidth * height);
    cudaMallocManaged(&dest, sizeof(float) * pWidth * height);
    //cudaMallocManaged(&img, sizeof(float) * pWidth * height);
    //cudaMemcpy(dest_img, img, sizeof(uint8_t) * pWidth * height, cudaMemcpyHostToDevice);

    int block_size = 256;
    int num_blocks = (pWidth + (block_size - 1)) / block_size;

    t1 = clock();
    computeColumn<<<num_blocks, block_size>>>(dest_img, mid, pWidth, height, radius, bpp);

    cudaDeviceSynchronize();

    stbi_image_free(img); //done with image

    num_blocks = (height+(block_size-1)) / block_size;

    computeRow<<<num_blocks, block_size>>>(mid, dest, pWidth, radius, bpp, height);

    cudaDeviceSynchronize();

    t2 = clock();
    cudaFree(mid); //done with mid

    //now back to int8 so we can save it
    img = (uint8_t*)malloc(sizeof(uint8_t) * pWidth * height);
    for (i = 0; i < pWidth * height; i++)
    {
        img[i] = (uint8_t)dest[i];
    }
    
    stbi_write_png("output.png", width, height, bpp, img, bpp * width);
    cudaFree(img);
    cudaFree(mid);
    cudaFree(dest);
    free(img);
    printf("Blur with radius %d complete in %f seconds\n", radius, (double)(t2 - t1) / (double)CLOCKS_PER_SEC);
}
