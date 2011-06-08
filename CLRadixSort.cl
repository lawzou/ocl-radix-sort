// OpenCL kernel sources for the CLRadixSort class
// the #include does not exist in OpenCL
// thus we simulate the #include "CLRadixSortParam.hpp" by
// string manipulations

#define NUM_BANKS 16 
#define LOG_NUM_BANKS 4 
#ifdef ZERO_BANK_CONFLICTS 
#define CONFLICT_FREE_OFFSET(n) \ 
    ((n) >> NUM_BANKS + (n) >> (2 * LOG_NUM_BANKS)) 
#else 
#define CONFLICT_FREE_OFFSET(n) ((n) >> LOG_NUM_BANKS) 
#endif


// compute the histogram for each radix and each virtual processor for the pass
__kernel void histogram(const __global int* d_Keys,
			__global int* d_Histograms,
			const int pass,
			__local int* loc_histo,
			const int n){

  int it = get_local_id(0);  // i local number of the processor
  int ig = get_global_id(0); // global number = i + g I

  int gr = get_group_id(0); // g group number

  int groups=get_num_groups(0);
  int items=get_local_size(0);

  // set the local histograms to zero
  for(int ir=0;ir<_RADIX;ir++){
    loc_histo[ir * items + it] = 0;
  }

  barrier(CLK_LOCAL_MEM_FENCE);  


  // range of keys that are analyzed by the work item
  int size= n/groups/items; // size of the sub-list
  int start= ig * size; // beginning of the sub-list

  int key,shortkey,k;

  // compute the index
  // the computation depends on the transposition
  for(int j= 0; j< size;j++){
#ifdef TRANSPOSE
    k= groups * items * j + ig;
#else
    k=j+start;
#endif
      
    key=d_Keys[k];   

    // extract the group of _BITS bits of the pass
    // the result is in the range 0.._RADIX-1
    shortkey=(( key >> (pass * _BITS)) & (_RADIX-1));  

    // increment the local histogram
    loc_histo[shortkey *  items + it ]++;
  }

  barrier(CLK_LOCAL_MEM_FENCE);  

  // copy the local histogram to the global one
  for(int ir=0;ir<_RADIX;ir++){
    d_Histograms[items * (ir * groups + gr) + it]=loc_histo[ir * items + it];
  }
  
  barrier(CLK_GLOBAL_MEM_FENCE);  


}

// initial transpose of the list for improving
// coalescent memory access
__kernel void transpose(const __global int* invect,
			__global int* outvect,
			const int nbcol,
			const int nbrow,
			const __global int* inperm,
			__global int* outperm,
			__local int* blockmat,
			__local int* blockperm,
			const int tilesize){
  
  int i0 = get_global_id(0)*tilesize;  // first row index
  int j = get_global_id(1);  // column index

  int jloc = get_local_id(1);  // local column index

  // fill the cache
  for(int iloc=0;iloc<tilesize;iloc++){
    int k=(i0+iloc)*nbcol+j;  // position in the matrix
    blockmat[iloc*tilesize+jloc]=invect[k];
#ifdef PERMUT 
    blockperm[iloc*tilesize+jloc]=inperm[k];
#endif
  }

  barrier(CLK_LOCAL_MEM_FENCE);  

  // first row index in the transpose
  int j0=get_group_id(1)*tilesize;

  // put the cache at the good place
  for(int iloc=0;iloc<tilesize;iloc++){
    int kt=(j0+iloc)*nbrow+i0+jloc;  // position in the transpose
    outvect[kt]=blockmat[jloc*tilesize+iloc];
#ifdef PERMUT 
      outperm[kt]=blockperm[jloc*tilesize+iloc];
#endif
  }
 
}

// each virtual processor reorders its data using the scanned histogram
__kernel void reorder(const __global int* d_inKeys,
		      __global int* d_outKeys,
		      __global int* d_Histograms,
		      const int pass,
		      __global int* d_inPermut,
		      __global int* d_outPermut,
		      __local int* loc_histo,
		      const int n){

  int it = get_local_id(0);
  int ig = get_global_id(0);

  int gr = get_group_id(0);
  int groups=get_num_groups(0);
  int items=get_local_size(0);

  int start= ig *(n/groups/items);
  int size= n/groups/items;

  // take the histogram in the cache
  for(int ir=0;ir<_RADIX;ir++){
    loc_histo[ir * items + it]=
      d_Histograms[items * (ir * groups + gr) + it];
  }
  barrier(CLK_LOCAL_MEM_FENCE);  


  int newpos,key,shortkey,k,newpost;

  for(int j= 0; j< size;j++){
#ifdef TRANSPOSE
      k= groups * items * j + ig;
#else
      k=j+start;
#endif
    key = d_inKeys[k];   
    shortkey=((key >> (pass * _BITS)) & (_RADIX-1)); 

    newpos=loc_histo[shortkey * items + it];


#ifdef TRANSPOSE
    int ignew,jnew;
    ignew= newpos/(n/groups/items);
    jnew = newpos%(n/groups/items);
    newpost = jnew * (groups*items) + ignew;
#else
    newpost=newpos;
#endif

    d_outKeys[newpost]= key;  // killing line !!!

#ifdef PERMUT 
      d_outPermut[newpost]=d_inPermut[k]; 
#endif

    newpos++;
    loc_histo[shortkey * items + it]=newpos;

  }  

}

// perform a exclusive parallel prefix sum on an array stored in local
// memory and return the sum in (*sum)
// the size of the array HAS to be twice the  number of work-items +1
// (the last element contains the total sum)
// ToDo: the function could be improved by avoiding bank conflicts...  


void localscan(__local int* temp){

  int it = get_local_id(0);
  int ig = get_global_id(0);
  int decale = 1; 
  int n=get_local_size(0) * 2 ;
 	
  // parallel prefix sum (algorithm of Blelloch 1990) 
  for (int d = n>>1; d > 0; d >>= 1){   
    barrier(CLK_LOCAL_MEM_FENCE);  
    if (it < d){  
      int ai = decale*(2*it+1)-1;  
      int bi = decale*(2*it+2)-1;  	
      temp[bi] += temp[ai];  
    }  
    decale *= 2; 
    //barrier(CLK_LOCAL_MEM_FENCE);  
  }
  
  // store the last element in the global sum vector
  // (maybe used in the next step for constructing the global scan)
  // clear the last element
  if (it == 0) {
    temp[n]=temp[n-1];
    temp[n - 1] = 0;
  }
                 
  // down sweep phase
  for (int d = 1; d < n; d *= 2){  
    decale >>= 1;  
    barrier(CLK_LOCAL_MEM_FENCE);

    if (it < d){  
      int ai = decale*(2*it+1)-1;  
      int bi = decale*(2*it+2)-1;  
         
      int t = temp[ai];  
      temp[ai] = temp[bi];  
      temp[bi] += t;   
    }  
    //barrier(CLK_LOCAL_MEM_FENCE);

  }  
  barrier(CLK_LOCAL_MEM_FENCE);
}



// perform a parallel prefix sum (a scan) on the local histograms
// (see Blelloch 1990) each workitem worries about two memories
// see also http://http.developer.nvidia.com/GPUGems3/gpugems3_ch39.html
__kernel void scanhistograms( __global int* histo,__local int* temp,__global int* globsum){


  int it = get_local_id(0);
  int ig = get_global_id(0);
  int gr=get_group_id(0);
  int sum;

  // load a part of the histogram into local memory
  temp[2*it] = histo[2*ig];  
  temp[2*it+1] = histo[2*ig+1];  
  barrier(CLK_LOCAL_MEM_FENCE);


  // scan the local vector with
  // the Blelloch's parallel algorithm
  localscan(temp);

  // remember the sum for the next scanning step
  if (it == 0){
    globsum[gr]=temp[2 * get_local_size(0)];
  }
  // write results to device memory

  histo[2*ig] = temp[2*it];  
  histo[2*ig+1] = temp[2*it+1];  

  barrier(CLK_GLOBAL_MEM_FENCE);

}  

// first step of the Satish algorithm: sort local blocks that fit into local
// memory with a radix=2^1 sorting algorithm
// and compute the groups histogram with the big radix=2^_BITS
// we thus need _BITS/1 passes
// let n=blocksize be the size of the local list
// the histogram is then of size 2^1 * n
// because we perform a localscan (see above) 
// it implies that the number of
// work-items nitems satisfies
// 2*nitems =  2 * n or
// nitems = n 
__kernel void sortblock( __global int* keys,   // the keys to be sorted
			 __local int* loc_in,  // a copy of the keys in local memory
			 __local int* loc_out,  // a copy of the keys in local memory
			 __local int* grhisto, // scanned group histogram
			 __global int* histo,   // not yet scanned global histogram
			 __global int* offset,   // offset of the radix of each group
			 const uint gpass)   // # of the pass
{   

  int it = get_local_id(0);
  int ig = get_global_id(0);
  int gr=get_group_id(0);
  int blocksize=get_local_size(0); // see above
  int sum;
  __local int* temp; // local pointer for memory exchanges

  // load keys into local memory
  loc_in[it] = keys[ig];  
  barrier(CLK_LOCAL_MEM_FENCE);

  // sort the local list with a radix=2 sort
  // also called split algorithm
  // for(int pass=0;pass < _BITS;pass++){
    
  //   // histogram of the pass
  //   int key,shortkey;
  //   key=loc_in[it];
  //   shortkey=(( key >> (gpass * _BITS) ) & (_RADIX-1));
  //   shortkey=(( shortkey >> pass ) & 1);  // key bit of the pass
  //   grhisto[shortkey*blocksize+it]=1;     // yes
  //   grhisto[(1-shortkey)*blocksize+it]=0;  // no
  //   barrier(CLK_LOCAL_MEM_FENCE);
    
  //   // scan (exclusive) the local vector
  //   // grhisto is of size blocksize+1
  //   // the last value is the total sum
  //   localscan(grhisto);
    
  //   // reorder in local memory    
  //   loc_out[grhisto[shortkey*blocksize+it]] = loc_in[it];  
  //   barrier(CLK_LOCAL_MEM_FENCE);

  //   // exchange old and new keys into local memory
  //   temp=loc_in;
  //   loc_in=loc_out;
  //   loc_out=temp;

  // } // end of split pass

  // now compute the histogram of the group
  // using the ordered keys and the already used
  // local memory

  if (it == 0) {
    loc_out[0]=0;
    loc_out[_RADIX]=blocksize;
  }
  else {
    int key1=loc_in[it-1];
    int key2=loc_in[it];
    //int gpass=0;
    int shortkey1=(( key1 >> (gpass * _BITS) ) & (_RADIX-1));  // key1 radix
    int shortkey2=(( key2 >> (gpass * _BITS) ) & (_RADIX-1));  // key2 radix
    
    for(int rad=shortkey1;rad<shortkey2;rad++){
      loc_out[rad+1]=it;
    }
  }
  barrier(CLK_LOCAL_MEM_FENCE);

  // compute the local histogram
  if (it < _RADIX) {
    grhisto[it]=loc_out[it+1]-loc_out[it];
  }
  //barrier(CLK_LOCAL_MEM_FENCE);
  
  // put the results into global memory

  int key=loc_in[it];
  //int gpass=0;
  int shortkey=(( key >> (gpass * _BITS) ) & (_RADIX-1));  // key radix
  
  // the keys
  keys[ig]=loc_in[it];

  // store the histograms and the offset
  if (it < _RADIX) {
    histo[it *(_N/_BLOCKSIZE)+gr]=grhisto[it]; // not coalesced !
    offset[gr *_RADIX + it]=loc_out[it]; // coalesced 
  }
  //barrier(CLK_GLOBAL_MEM_FENCE);
}  

// reorder step of the Satish algorithm
// use the scanned histogram and the block offsets to reorder
// the locally reordered keys
// many memeory access are coalesced because of the initial ordering
__kernel void reordersatish( const __global int* inkeys,   // the keys to be sorted
			     __global int* outkeys,  //  the sorted keys 
			     __local int* locoffset,  // a copy of the offset in local memory
			     __local int* grhisto, // scanned group histogram
			     const __global int* histo,   //  global scanned histogram
			     const __global int* offset,   // offset of the radix of each group
			     const uint gpass)   // # of the pass
{

  int it = get_local_id(0);
  int ig = get_global_id(0);
  int gr=get_group_id(0);
  int blocksize=get_local_size(0);
  
  // store locally the histograms and the offset
  if (it < _RADIX) {
    grhisto[it]=histo[it *(_N/_BLOCKSIZE)+gr]; // not coalesced !
    locoffset[it]=offset[gr *_RADIX + it]; // coalesced 
  }
  barrier(CLK_LOCAL_MEM_FENCE);

  int key = inkeys[ig];  

  int shortkey=(( key >> (gpass * _BITS) ) & (_RADIX-1));  // key radix

  // move the key at the good place, using
  // the scanned histogram and the offset
  outkeys[grhisto[shortkey]+it-locoffset[shortkey]]=key;

  barrier(CLK_GLOBAL_MEM_FENCE);
}  


// use the global sum for updating the local histograms
// each work item updates two values
__kernel void pastehistograms( __global int* histo,const __global int* globsum){


  int ig = get_global_id(0);
  int gr=get_group_id(0);

  int s;

  s=globsum[gr];
  
  // write results to device memory
  histo[2*ig] += s;  
  histo[2*ig+1] += s;  

  barrier(CLK_GLOBAL_MEM_FENCE);

}  



