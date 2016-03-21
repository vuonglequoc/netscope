module.exports =
class Analyzer
    constructor: ->
        
    analyze: (net) ->
        ## Add Input/Output Dimensions + Channels to each Node / Layer
        # shape.dim: (    N   x   K   x   W   x   H   )
        #              batch   channel  width   height
        #               chIn    chOut   wIn     wOut
    
        for n in net.nodes
            # init to zero
            d = n.analysis
            d.wIn  = d.hIn = d.wOut = d.hOut = 0
            d.chIn = d.chOut = 0
            d.comp = {macc: 0, comp: 0, add: 0, div: 0, exp: 0}
            d.mem  = 0
        
            layertype = n.type.toLowerCase()
            parent = n.parents[0]?.analysis
                
            switch layertype
                when "data"
                    #dimensions
                    if n.attribs.input_param?.shape?
                        shape = n.attribs.input_param.shape
                        d.chIn  = shape.dim[1]
                        d.wIn   = shape.dim[2]
                        d.hIn   = shape.dim[3]
                    else if n.attribs.transform_param?.crop_size?
                        d.wIn = d.hIn = n.attribs.transform_param.crop_size
                        d.chIn = 3
                    else
                        onerror('Unknown Input Dimensions')
                        debugger;
                    d.wOut = d.wIn
                    d.hOut = d.hIn
                    d.chOut = d.chIn
                    #computation
                    #-- none
                
                when "convolution"
                    #dimensions
                    params   = n.attribs.convolution_param
                    kernel_w = params.kernel_w ? params.kernel_size
                    kernel_h = params.kernel_h ? params.kernel_size
                    stride_w = params.stride_w ? (params.stride ? 1)
                    stride_h = params.stride_h ? (params.stride ? 1)
                    pad_w    = params.pad_w ? (params.pad ? 0)
                    pad_h    = params.pad_h ? (params.pad ? 0)
                    numout   = params.num_output
                    d.wIn    = parent.wOut
                    d.hIn    = parent.hOut
                    # according to http://caffe.berkeleyvision.org/tutorial/layers.html and https://github.com/BVLC/caffe/issues/3656 
                    d.wOut = Math.floor((d.wIn + 2*pad_w - kernel_w) / stride_w) + 1
                    d.hOut = Math.floor((d.hIn + 2*pad_h - kernel_h) / stride_h) + 1
                    d.chIn = parent.chOut
                    d.chOut = numout
                    #computation
                    d.comp.macc = (kernel_w*kernel_h)*(d.wOut*d.hOut)*d.chIn*d.chOut
                
                when "innerproduct", "inner_product"
                    #dimensions
                    numout = n.attribs.inner_product_param.num_output
                    d.wIn  = parent.wOut
                    d.hIn  = parent.hOut
                    d.chIn = parent.chOut
                    d.wOut = 1
                    d.hOut = 1
                    d.chOut = numout
                    #computation
                    d.comp.macc = (d.wIn*d.hIn)*d.chIn*d.chOut
                
                when "pooling"
                    #dimensions
                    params = n.attribs.pooling_param
                    kernel = params.kernel_size
                    stride = params.stride ? 1
                    pad    = params.pad ? 0
                    isglobal = params.global_pooling ? 0
                    pooltype = (params.pool ? 'MAX').toUpperCase()
                    d.wIn  = parent.wOut
                    d.hIn  = parent.hOut
                    d.chIn = parent.chOut
                    d.chOut = d.chIn
                    # according to http://caffe.berkeleyvision.org/tutorial/layers.html and https://github.com/BVLC/caffe/issues/3656
                    d.wOut = Math.ceil((d.wIn + 2*pad - kernel) / stride) + 1
                    d.hOut = Math.ceil((d.hIn + 2*pad - kernel) / stride) + 1
                    if isglobal
                        d.wOut = d.hOut = 1
                    #computation
                    num_ops = if isglobal then ((d.wIn*d.hIn)*d.chIn) else ((d.wOut*d.hOut)*kernel*kernel*d.chOut)
                    if pooltype == 'MAX'
                        d.comp.comp = num_ops
                    else if pooltype == 'AVE'
                        d.comp.add = num_ops
                        #d.comp.div = (d.wOut*d.hOut*d.chOut) #divide by const.
                    else
                        onerror "Unknown pooling type #{pooltype}"
                
                when "batchnorm"
                    #dimensions
                    d.wIn  = parent.wOut
                    d.hIn  = parent.hOut
                    d.wOut = d.wIn
                    d.hOut = d.hIn
                    d.chOut = d.chIn = parent.chOut
                    #computation
                    # BN: subtract mean, divide by variance for each channel
                    # averages during training: over spatial dims + batch
                    d.comp.add = d.wIn*d.hIn*d.chIn
                    d.comp.div = d.wIn*d.hIn*d.chIn
            
                when "lrn"
                    #dimensions
                    #default mode: ACROSS_CHANNELS
                    mode   = n.attribs.lrn_param.norm_region ? 'ACROSS_CHANNELS'
                    size   = n.attribs.lrn_param.local_size
                    d.wIn  = parent.wOut
                    d.hIn  = parent.hOut
                    d.wOut = d.wIn
                    d.hOut = d.hIn
                    d.chOut = d.chIn = parent.chOut
                    #computation
                    #  Each input value is divided by (1+(α/n)∑xi^2)^β
                    num_inputs = d.wIn*d.hIn*d.chIn
                    d.comp.macc = num_inputs*size   # (∑xi^2)
                    d.comp.add = num_inputs         # (1+...)
                    d.comp.exp = num_inputs         # (...)^β
                    d.comp.div = num_inputs*2       # (α/n)*... + divide by sum
                
                when "concat"
                    #dimensions
                    d.wIn = parent.wOut
                    d.hIn = parent.hOut
                    d.wOut = d.wIn
                    d.hOut = d.hIn
                    # sum up channels from inputs
                    d.chIn += p.analysis.chOut for p in n.parents
                    d.chOut = d.chIn
                    # check input dimensions
                    failed = failed || (p.analysis.wOut != d.wIn || p.analysis.hOut != d.hIn) for p in n.parents
                    window.onerror('CONCAT: input dimensions dont agree!') if failed
                    #computation
                    # --none
     
                when "relu", "dropout"
                    #dimensions
                    d.wIn = parent.wOut
                    d.hIn = parent.hOut
                    d.wOut = d.wIn
                    d.hOut = d.hIn
                    d.chOut = d.chIn = parent.chOut
                    #computation
                    d.comp.comp = d.wIn*d.hIn*d.chIn
                    
                when "softmax", "softmaxwithloss", "softmax_loss"
                    #dimensions
                    d.wIn = parent.wOut
                    d.hIn = parent.hOut
                    d.wOut = d.wIn
                    d.hOut = d.hIn
                    d.chOut = d.chIn = parent.chOut
                    #computation
                    d.comp.exp = d.wIn*d.hIn*d.chIn
                    d.comp.add = d.wIn*d.hIn*d.chIn
                    d.comp.div = d.wIn*d.hIn*d.chIn
                
                when "flatten"
                    #dimensions
                    d.wIn = parent.wOut
                    d.hIn = parent.hOut      
                    d.chIn = parent.chOut
                    d.wOut = d.hOut = 1
                    d.chOut = d.chIn * d.wIn * d.hIn
                    #computation
                    # --none
                    
                when "implicit"
                    #dimensions
                    d.wIn = d.hIn = 0     
                    d.chIn = 0
                    d.wOut = d.hOut = 0
                    d.chOut = 0
                    #computation
                    # --none
                
                else # unknown layer;  print error message;
                    onerror('Unknown Layer: '+layertype)
                    console.log(n)
                    debugger;

            # add dimensions to node attributes
            # so they show in graph tooltips
            trivial_layers = ["relu", "softmax", "softmaxwithloss", "softmax_loss", "dropout", "concat"]
            if $.inArray(layertype, trivial_layers) == -1
                _.extend(n.attribs, {
                analysis: {
                    in: d.chIn+'ch ⋅ '+d.wIn+'×'+d.hIn,
                    out: d.chOut+'ch ⋅ '+d.wOut+'×'+d.hOut
                    }} )
                
        return net