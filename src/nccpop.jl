mutable struct nccpop_data
    n # number of variables
    m # number of constraints
    numeq # number of equality constraints
    supp # support data
    coe # coefficient data
    partition # the first 'partition' variables commutes with the remaining variables
    constraint # nothing or "projection" or "unipotent"
    obj # "eigen" or "trace"
    basis # monomial bases
    ksupp # extended support at the k-th step
    sb # sizes of different blocks
    numb # numbers of different blocks
    blocks # block structure
    cl # numbers of blocks
    blocksize # sizes of blocks
    moment # moment matrix
    GramMat # Gram matrix
end

"""
    opt,data = nctssos_first(pop::Vector{Polynomial{false, T}} where T<:Number, x::Vector{PolyVar{false}},
        order::Int; numeq=0, reducebasis=false, TS="block", obj="eigen", merge=false, md=3, solve=true, Gram=false, QUIET=false)

Compute the first step of the NCTSSOS hierarchy for constrained noncommutative polynomial optimization with
relaxation order `order`.
Return the optimum and other auxiliary data.

# Arguments
- `pop`: the vector of the objective function, inequality constraints, and equality constraints.
- `x`: the set of noncommuting variables.
- `order`: the relaxation order of the moment-SOHS hierarchy.
- `numeq`: the number of equality constraints.
"""

function nctssos_first(pop::Vector{Polynomial{false, T}} where T<:Number, x::Vector{PolyVar{false}},
    order::Int; numeq=0, reducebasis=false, TS="block", obj="eigen", merge=false, md=3, solve=true, Gram=false, QUIET=false,
    solver="Mosek", partition=0, constraint=nothing, cosmo_setting=cosmo_para())
    n,supp,coe = polys_info(pop, x)
    opt,data = nctssos_first(supp, coe, n, order, numeq=numeq, reducebasis=reducebasis, TS=TS, obj=obj, merge=merge,
    md=md, QUIET=QUIET, solve=solve, solver=solver, Gram=Gram, partition=partition, constraint=constraint, cosmo_setting=cosmo_setting)
    return opt,data
end

function polys_info(pop, x)
    n = length(x)
    m = length(pop)-1
    coe = Vector{Vector{Float64}}(undef, m+1)
    supp = Vector{Vector{Vector{UInt16}}}(undef, m+1)
    for k = 1:m+1
        mon = monomials(pop[k])
        coe[k] = coefficients(pop[k])
        supp[k] = [UInt16[] for i=1:length(mon)]
        for i = 1:length(mon)
            ind = mon[i].z .> 0
            vars = mon[i].vars[ind]
            exp = mon[i].z[ind]
            for j = 1:length(vars)
                l = bfind(x, n, vars[j], rev=true)
                append!(supp[k][i], l*ones(UInt16, exp[j]))
            end
        end
    end
    return n,supp,coe
end

function nctssos_first(supp::Vector{Vector{Vector{UInt16}}}, coe, n::Int64, order::Int64; numeq=0, reducebasis=false, TS="block",
    obj="eigen", merge=false, md=3, solve=true, solver="Mosek", Gram=false, QUIET=false, partition=0, constraint=nothing, cosmo_setting=cosmo_para())
    if QUIET == false
        println("********************************** NCTSSOS **********************************")
        println("Version 0.2.0, developed by Jie Wang, 2020--2023")
        println("NCTSSOS is launching...")
    end
    m = length(supp)-1
    dg = [maximum(length.(supp[i])) for i=2:m+1]
    if obj == "trace"
        supp[1],coe[1] = cyclic_canon(supp[1], coe[1])
    else
        supp[1],coe[1] = sym_canon(supp[1], coe[1])
    end
    basis = Vector{Vector{Vector{UInt16}}}(undef, m+1)
    basis[1] = get_ncbasis(n, order, binary=constraint!==nothing)
    if partition > 0
        ind = [_comm(basis[1][i], partition) == basis[1][i] for i=1:length(basis[1])]
        basis[1] = basis[1][ind]
    end
    ksupp = copy(supp[1])
    for i = 1:m
        basis[i+1] = get_ncbasis(n, order-Int(ceil(dg[i]/2)), binary=constraint!==nothing)
        if partition > 0
            ind = [_comm(basis[i+1][k], partition) == basis[i+1][k] for k=1:length(basis[i+1])]
            basis[i+1] = basis[i+1][ind]
        end
        if obj == "trace"
            append!(ksupp, [min(_cyclic_canon(word), _cyclic_canon(reverse(word))) for word in supp[i+1]])
        else
            append!(ksupp, _sym_canon.(supp[i+1]))
        end
    end
    if obj == "trace"
        append!(ksupp, [_cyclic_canon([basis[1][i][end:-1:1]; basis[1][i]]) for i=1:length(basis[1])])
    else
        append!(ksupp, [[basis[1][i][end:-1:1]; basis[1][i]] for i=1:length(basis[1])])
    end
    if partition > 0
        ksupp = _comm.(ksupp, partition)
    end
    if constraint !== nothing
        reduce_cons!.(ksupp, constraint = constraint)
    end
    sort!(ksupp)
    unique!(ksupp)
    if TS != false && QUIET == false
        println("Starting to compute the block structure...")
    end
    time = @elapsed begin
    blocks,cl,blocksize,sb,numb,_ = get_nccblocks(m, ksupp, supp[2:end], basis, TS=TS, obj=obj, QUIET=QUIET,
    merge=merge, md=md, partition=partition, constraint=constraint)
    if reducebasis == true && obj == "eigen" && constraint === nothing
        gsupp = get_ncgsupp(m, supp, basis[2:end], blocks[2:end], cl[2:end], blocksize[2:end])
        psupp = copy(supp[1])
        push!(psupp, UInt16[])
        append!(psupp, gsupp)
        psupp = psupp[is_sym.(psupp)]
        basis[1],flag = reducebasis!(psupp, basis[1], blocks[1], cl[1], blocksize[1])
        if flag == 1
            ksupp = copy(supp[1])
            for i = 1:m
                append!(ksupp, _sym_canon.(supp[i+1]))
            end
            append!(ksupp, [[basis[1][i][end:-1:1]; basis[1][i]] for i=1:length(basis[1])])
            sort!(ksupp)
            unique!(ksupp)
            blocks,cl,blocksize,sb,numb,_ = get_nccblocks(m, ksupp, supp[2:end], basis, TS=TS, obj=obj, QUIET=QUIET, merge=merge, md=md)
        end
    end
    end
    if TS != false && QUIET == false
        mb = maximum(maximum.(sb))
        println("Obtained the block structure in $time seconds. The maximal size of blocks is $mb.")
    end
    opt,ksupp,moment,GramMat = ncblockcpop(m, supp, coe, basis, blocks, cl, blocksize, numeq=numeq, QUIET=QUIET, obj=obj,
    solve=solve, solver=solver, Gram=Gram, partition=partition, constraint=constraint, cosmo_setting=cosmo_setting)
    data = nccpop_data(n, m, numeq, supp, coe, partition, constraint, obj, basis, ksupp, sb, numb, blocks, cl, blocksize, moment, GramMat)
    return opt,data
end

function nctssos_higher!(data::nccpop_data; TS="block", merge=false, md=3, solve=true, solver="Mosek", Gram=false, QUIET=false, cosmo_setting=cosmo_para())
    m = data.m
    numeq = data.numeq
    supp = data.supp
    coe = data.coe
    partition = data.partition
    constraint = data.constraint
    obj = data.obj
    basis = data.basis
    ksupp = data.ksupp
    sb = data.sb
    numb = data.numb
    blocks = data.blocks
    cl = data.cl
    blocksize = data.blocksize
    if QUIET == false
        println("Starting to compute the block structure...")
    end
    time = @elapsed begin
    blocks, cl, blocksize, sb, numb, status = get_nccblocks(m, ksupp, supp[2:end], basis, blocks=blocks,
    cl=cl, blocksize=blocksize, sb=sb, numb=numb, TS=TS, obj=obj, QUIET=QUIET, merge=merge, md=md,
    partition=partition, constraint=constraint)
    end
    opt = nothing
    if status == 1
        if QUIET == false
            mb = maximum(maximum.(sb))
            println("Obtained the block structure in $time seconds. The maximal size of blocks is $mb.")
        end
        opt,ksupp,moment,GramMat = ncblockcpop(m, supp, coe, basis, blocks, cl, blocksize, numeq=numeq, QUIET=QUIET, obj=obj,
        solve=solve, solver=solver, Gram=Gram, partition=partition, constraint=constraint, cosmo_setting=cosmo_setting)
        data.moment = moment
        data.GramMat = GramMat
    end
    data.ksupp = ksupp
    data.sb = sb
    data.numb = numb
    data.blocks = blocks
    data.cl = cl
    data.blocksize = blocksize
    return opt,data
end

function get_ncgsupp(m, supp, gbasis, gblocks, gcl, gblocksize)
    gsupp = Vector{UInt16}[]
    for k = 1:m, i = 1:gcl[k], j = 1:gblocksize[k][i], r = j:gblocksize[k][i], s = 1:length(supp[k+1])
        @inbounds bi = [gbasis[k][gblocks[k][i][j]][end:-1:1]; supp[k+1][s]; gbasis[k][gblocks[k][i][r]]]
        push!(gsupp, bi)
    end
    return gsupp
end

function reducebasis!(psupp, basis, blocks, cl, blocksize)
    init = 0
    flag = 0
    check = 0
    while init == 0 || check > 0
        init = 1
        check = 0
        for i = 1:cl
            if blocksize[i] > 1
                for j = 1:blocksize[i], r = 1:blocksize[i]
                    if j != r
                        @inbounds bi = [basis[blocks[i][j]][end:-1:1]; basis[blocks[i][r]]]
                        if is_sym(bi)
                            push!(psupp, bi)
                        end
                    end
                end
            end
        end
        sort!(psupp)
        unique!(psupp)
        lpsupp = length(psupp)
        for i = 1:cl
            lo = blocksize[i]
            indexb = [k for k=1:lo]
            j = 1
            while lo >= j
                bi = [basis[blocks[i][indexb[j]]][end:-1:1]; basis[blocks[i][indexb[j]]]]
                Locb = bfind(psupp, lpsupp, bi)
                if Locb === nothing
                   check = 1
                   flag = 1
                   deleteat!(indexb, j)
                   lo = lo-1
                else
                   j += 1
                end
            end
            blocks[i] = blocks[i][indexb]
            blocksize[i] = lo
        end
    end
    if flag == 1
       indexb = blocks[1]
       for i = 2:cl
           indexb = append!(indexb, blocks[i])
       end
       sort!(indexb)
       unique!(indexb)
       return basis[indexb],flag
    else
       return basis,flag
    end
end

function get_nccgraph(ksupp, supp, basis; obj="eigen", partition=0, constraint=nothing)
    lb = length(basis)
    lksupp = length(ksupp)
    G = SimpleGraph(lb)
    for i = 1:lb, j = i+1:lb
        r = 1
        while r <= length(supp)
            bi = [basis[i][end:-1:1]; supp[r]; basis[j]]
            bi = reduce!(bi, obj=obj, partition=partition, constraint=constraint)
            if bfind(ksupp, lksupp, bi) !== nothing
               break
            else
               r += 1
            end
        end
        if r <= length(supp)
           add_edge!(G, i, j)
        end
    end
    return G
end

function get_nccblocks(m, ksupp, gsupp, basis; blocks=[], cl=[], blocksize=[], sb=[], numb=[],
    TS="block", obj="eigen", QUIET=true, merge=false, md=3, partition=0, constraint=nothing)
    if isempty(blocks)
        blocks = Vector{Vector{Vector{UInt16}}}(undef, m+1)
        blocksize = Vector{Vector{UInt16}}(undef, m+1)
        cl = Vector{UInt16}(undef, m+1)
    end
    if TS == false
        for k = 1:m+1
            blocks[k] = [[i for i=1:length(basis[k])]]
            blocksize[k] = [length(basis[k])]
            cl[k] = 1
        end
        nsb = Int.(blocksize[1])
        nnumb = [1]
        status = 1
    else
        G = get_ncgraph(ksupp, basis[1], obj=obj, partition=partition, constraint=constraint)
        if TS == "block"
            blocks[1] = connected_components(G)
            blocksize[1] = length.(blocks[1])
            cl[1] = length(blocksize[1])
        else
            blocks[1],cl[1],blocksize[1] = chordal_cliques!(G, method=TS, minimize=false)
            if merge == true
                blocks[1],cl[1],blocksize[1] = clique_merge!(blocks[1], d=md, QUIET=true)
            end
        end
        nsb = sort(Int.(unique(blocksize[1])), rev=true)
        nnumb = [sum(blocksize[1].== i) for i in nsb]
        if isempty(sb) || nsb!=sb || nnumb!=numb
            status = 1
            if QUIET == false
                println("-----------------------------------------------------------------------------")
                println("The sizes of PSD blocks:\n$nsb\n$nnumb")
                println("-----------------------------------------------------------------------------")
            end
            for k = 1:m
                G = get_nccgraph(ksupp, gsupp[k], basis[k+1], obj=obj, partition=partition, constraint=constraint)
                if TS == "block"
                    blocks[k+1] = connected_components(G)
                    blocksize[k+1] = length.(blocks[k+1])
                    cl[k+1] = length(blocksize[k+1])
                else
                    blocks[k+1],cl[k+1],blocksize[k+1] = chordal_cliques!(G, method=TS, minimize=false)
                    if merge == true
                        blocks[k+1],cl[k+1],blocksize[k+1] = clique_merge!(blocks[k+1], d=md, QUIET=true)
                    end
                end
            end
        else
            status = 0
            if QUIET == false
                println("No higher TS step of the NCTSSOS hierarchy!")
            end
        end
    end
    return blocks,cl,blocksize,nsb,nnumb,status
end

function ncblockcpop(m, supp, coe, basis, blocks, cl, blocksize; numeq=0, QUIET=true, obj="eigen",
    solve=true, solver="Mosek", Gram=false, partition=0, constraint=nothing, cosmo_setting=cosmo_para())
    ksupp = Vector{UInt16}[]
    for i = 1:cl[1], j = 1:blocksize[1][i], r = j:blocksize[1][i]
        @inbounds bi = [basis[1][blocks[1][i][j]][end:-1:1]; basis[1][blocks[1][i][r]]]
        @inbounds push!(ksupp, bi)
    end
    gsupp = get_ncgsupp(m, supp, basis[2:end], blocks[2:end], cl[2:end], blocksize[2:end])
    append!(ksupp, gsupp)
    ksupp = reduce!.(ksupp, obj=obj, partition=partition, constraint=constraint)
    sort!(ksupp)
    unique!(ksupp)
    lksupp = length(ksupp)
    if QUIET == false
        println("There are $lksupp affine constraints.")
    end
    objv = moment = GramMat = nothing
    if solve == true
        if QUIET==false
            println("Assembling the SDP...")
        end
        if solver == "Mosek"
            model = Model(optimizer_with_attributes(Mosek.Optimizer))
        elseif solver == "COSMO"
            model = Model(optimizer_with_attributes(COSMO.Optimizer, "eps_abs" => cosmo_setting.eps_abs, "eps_rel" => cosmo_setting.eps_rel, "max_iter" => cosmo_setting.max_iter))
        else
            @error "The solver is currently not supported!"
            return nothing,nothing,nothing,nothing
        end
        set_optimizer_attribute(model, MOI.Silent(), QUIET)
        time = @elapsed begin
        cons = [AffExpr(0) for i=1:lksupp]
        pos = Vector{Union{VariableRef,Symmetric{VariableRef}}}(undef, cl[1])
        for i = 1:cl[1]
            bs = blocksize[1][i]
            if bs == 1
               @inbounds pos[i] = @variable(model, lower_bound=0)
               @inbounds bi = [basis[1][blocks[1][i][1]][end:-1:1]; basis[1][blocks[1][i][1]]]
               bi = reduce!(bi, obj=obj, partition=partition, constraint=constraint)
               Locb = bfind(ksupp, lksupp, bi)
               @inbounds add_to_expression!(cons[Locb], pos[i])
            else
               @inbounds pos[i] = @variable(model, [1:bs, 1:bs], PSD)
               for j = 1:bs, r = j:bs
                   @inbounds bi = [basis[1][blocks[1][i][j]][end:-1:1]; basis[1][blocks[1][i][r]]]
                  bi = reduce!(bi, obj=obj, partition=partition, constraint=constraint)
                   Locb = bfind(ksupp, lksupp, bi)
                   if j == r
                       @inbounds add_to_expression!(cons[Locb], pos[i][j,r])
                   else
                       @inbounds add_to_expression!(cons[Locb], 2, pos[i][j,r])
                   end
               end
            end
        end
        gpos = Vector{Vector{Union{VariableRef,Symmetric{VariableRef}}}}(undef, m)
        for k = 1:m
            gpos[k] = Vector{Union{VariableRef,Symmetric{VariableRef}}}(undef, cl[k+1])
            for i = 1:cl[k+1]
                bs = blocksize[k+1][i]
                if bs == 1
                    if k <= m-numeq
                        gpos[k][i] = @variable(model, lower_bound=0)
                    else
                        gpos[k][i] = @variable(model)
                    end
                    for s = 1:length(supp[k+1])
                        @inbounds bi = [basis[k+1][blocks[k+1][i][1]][end:-1:1]; supp[k+1][s]; basis[k+1][blocks[k+1][i][1]]]
                        bi = reduce!(bi, obj=obj, partition=partition, constraint=constraint)
                        Locb = bfind(ksupp, lksupp, bi)
                        @inbounds add_to_expression!(cons[Locb], coe[k+1][s], gpos[k][i])
                    end
                else
                    if k <= m-numeq
                       gpos[k][i] = @variable(model, [1:bs, 1:bs], PSD)
                    else
                       gpos[k][i] = @variable(model, [1:bs, 1:bs], Symmetric)
                    end
                    for j = 1:bs, r = j:bs, s = 1:length(supp[k+1])
                        @inbounds bi=[basis[k+1][blocks[k+1][i][j]][end:-1:1]; supp[k+1][s]; basis[k+1][blocks[k+1][i][r]]]
                        bi = reduce!(bi, obj=obj, partition=partition, constraint=constraint)
                        Locb = bfind(ksupp, lksupp, bi)
                        if j == r
                            @inbounds add_to_expression!(cons[Locb], coe[k+1][s], gpos[k][i][j,r])
                        else
                            @inbounds add_to_expression!(cons[Locb], 2*coe[k+1][s], gpos[k][i][j,r])
                        end
                    end
                end
            end
        end
        bc = zeros(lksupp)
        for i = 1:length(supp[1])
            Locb = bfind(ksupp, lksupp, supp[1][i])
            if Locb === nothing
               @error "The monomial basis is not enough!"
               return nothing,nothing,nothing,nothing
            else
               bc[Locb] = coe[1][i]
            end
        end
        @variable(model, lower)
        cons[1] += lower
        @constraint(model, con, cons.==bc)
        @objective(model, Max, lower)
        end
        if QUIET == false
            println("SDP assembling time: $time seconds.")
            println("Solving the SDP...")
        end
        time = @elapsed begin
        optimize!(model)
        end
        if QUIET == false
            println("SDP solving time: $time seconds.")
        end
        status = termination_status(model)
        objv = objective_value(model)
        if status != MOI.OPTIMAL
           println("termination status: $status")
           status = primal_status(model)
           println("solution status: $status")
        end
        if QUIET == false
            println("optimum = $objv")
        end
        if Gram == true
            GramMat = Vector{Vector{Union{Float64,Matrix{Float64}}}}(undef, m+1)
            GramMat[1] = [value.(pos[i]) for i = 1:cl[1]]
            for k = 1:m
                GramMat[k+1] = [value.(gpos[k][i]) for i = 1:cl[k+1]]
            end
        end
        dual_var = -dual.(con)
        moment = Vector{Matrix{Float64}}(undef, cl[1])
        for i = 1:cl[1]
            moment[i] = zeros(blocksize[1][i],blocksize[1][i])
            for j = 1:blocksize[1][i], k = j:blocksize[1][i]
                @inbounds bi = [basis[1][blocks[1][i][j]][end:-1:1]; basis[1][blocks[1][i][k]]]
                bi = reduce!(bi, obj=obj, partition=partition, constraint=constraint)
                Locb = bfind(ksupp, lksupp, bi)
                moment[i][j,k] = dual_var[Locb]
            end
            moment[i] = Symmetric(moment[i],:U)
        end
    end
    return objv,ksupp,moment,GramMat
end
