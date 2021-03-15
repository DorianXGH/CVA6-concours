#include <stdio.h>
#include <stdlib.h>
  
int main(void)
{
    volatile int res = 0;
    for (int i = 1; i < 200; i++) {
        res = res / i;
        volatile int temp = 0; 
        for (int j = 0; j < i; j++) {
            temp += j;
        }
        res += temp;
    }

    printf("done!\n"); 
     
    //wait end of uart frame
    volatile int c, d;  
    for (c = 1; c <= 32767; c++)
        for (d = 1; d <= 32767; d++)
        {}
          
    return(0);
}

