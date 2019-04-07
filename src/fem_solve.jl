function solve{islinear,isstochastic,MeshType<:FEMMesh,F1,F2,F3,F4,F5,F6,F7,DiffType}(
  prob::PoissonProblem{islinear,isstochastic,MeshType,F1,F2,F3,F4,F5,F6,F7,DiffType},
  alg::FEMDiffEqPoisson;solver::Symbol=:Direct,autodiff::Bool=false,
  method=:trust_region,show_trace=false,iterations=1000,kwargs...)
  #Assemble Matrices
  A,M,area = assemblematrix(prob.mesh,lumpflag=true)
  #Unroll some important constants
  @unpack dt,bdnode,node,elem,N,NT,freenode,dirichlet,neumann = prob.mesh
  @unpack f,Du,f,gD,gN,analytic,u0,numvars,σ,noisetype,D = prob

  #Setup f quadrature
  mid = Array{eltype(node)}(size(@view node[vec(@view elem[:,2]),:])...,3)
  mid[:,:,1] .= (view(node,vec(@view elem[:,2]),:) .+ @view node[vec(@view elem[:,3]),:])./2
  mid[:,:,2] .= (view(node,vec(@view elem[:,3]),:) .+ @view node[vec(@view elem[:,1]),:])./2
  mid[:,:,3] .= (view(node,vec(@view elem[:,1]),:) .+ @view node[vec(@view elem[:,2]),:])./2

  #Setup u
  u = copy(u0)
  u[bdnode] = gD(@view node[bdnode,:])

  #isstochastic Part
  if isstochastic
    rands = getNoise(u,node,elem,noisetype=noisetype)
    dW = next(rands)
    rhs = (u) -> quadfbasis(f,gD,gN,A,u,node,elem,area,bdnode,mid,N,NT,dirichlet,neumann,islinear,numvars) + quadfbasis(σ,gD,gN,A,u,node,elem,area,bdnode,mid,N,NT,dirichlet,neumann,islinear,numvars).*dW
  else #Not isstochastic
    rhs = (u) -> quadfbasis(f,gD,gN,A,u,node,elem,area,bdnode,mid,N,NT,dirichlet,neumann,islinear,numvars)
  end
  Dinv = map((x)->inv(x),D) # Special form so that units work
  #Solve
  if islinear
    if solver==:Direct
      u[freenode,:]=A[freenode,freenode]\(Dinv.*rhs(u))[freenode]
    elseif solver==:CG
      for i = 1:size(u,2)
        u[freenode,i],ch=cg!(u[freenode,i],A[freenode,freenode],Dinv.*rhs(u)[freenode,i]) # Needs diffusion constant
      end
    elseif solver==:GMRES
      for i = 1:size(u,2)
        u[freenode,i],ch=gmres!(u[freenode,i],A[freenode,freenode],Dinv.*rhs(u)[freenode,i]) # Needs diffusion constants
      end
    end
    #Adjust result
    if isempty(dirichlet) #isPureneumann
      patchArea = accumarray(vec(elem),[area;area;area]/3, [N 1])
      uc = sum(u.*patchArea)/sum(area)
      u = u - uc   # Impose integral of u = 0
    end
  else #Nonlinear
    rhs! = (resid,u) -> begin
      u = reshape(u,N,numvars)
      resid = reshape(resid,N,numvars)
      resid[freenode,:]=D.*(A[freenode,freenode]*u[freenode,:])-rhs(u)[freenode,:]
      u = vec(u)
      resid = vec(resid)
    end
    u = vec(u)
    nlres = NLsolve.nlsolve(rhs!,u,autodiff=autodiff,method=method,show_trace=show_trace,iterations=iterations)
    u = nlres.zero
    if numvars > 1
      u = reshape(u,N,numvars)
    end
  end

  #Return
  if typeof(analytic)!=Void # True solution exists
    return(FEMSolution([u],analytic(node),Du,prob))
  else #No true solution
    return(FEMSolution([u],prob))
  end
end

## Evolution Equation Solvers
#Note
#rhs(u,i) = Dm[freenode,freenode]*u[freenode,:] + dt*f(node,(i-.5)*dt)[freenode] #Nodel interpolation 1st 𝒪
function solve{islinear,isstochastic,MeshType<:FEMMesh,F,F2,F3,F4,F5,F6,F7,DiffType}(
  prob::HeatProblem{islinear,isstochastic,MeshType,F,F2,F3,F4,F5,F6,F7,DiffType},
  alg::AbstractHeatFEMAlgorithm;
  solver::Symbol=:LU,save_everystep::Bool = false,timeseries_steps::Int = 100,
  autodiff::Bool=false,method=:trust_region,show_trace=false,iterations=1000,
  progress_steps::Int=1000,progressbar::Bool=false,progressbar_name="FEM",kwargs...)
  #Assemble Matrices
  A,M,area = assemblematrix(prob.mesh,lumpflag=true)

  #Unroll some important constants
  @unpack dt,tspan,bdnode,node,elem,N,NT,freenode,dirichlet,neumann = prob.mesh
  @unpack f,u0,Du,gD,gN,analytic,numvars,σ,noisetype,D = prob

  if dt != 0
    numiters = round(Int64,tspan[2]/dt)
  else
    numiters = 0
  end

  #Set Initial
  u = copy(u0)
  t = tspan[1]

  #Setup timeseries

  timeseries = Vector{typeof(u)}(0)
  push!(timeseries,copy(u))
  ts = Float64[t]

  sqrtdt= sqrt(dt)
  #Setup f quadraturef
  mid = Array{eltype(node)}(size(node[vec(elem[:,2]),:])...,3)
  mid[:,:,1] = (node[vec(elem[:,2]),:]+node[vec(elem[:,3]),:])/2
  mid[:,:,2] = (node[vec(elem[:,3]),:]+node[vec(elem[:,1]),:])/2
  mid[:,:,3] = (node[vec(elem[:,1]),:]+node[vec(elem[:,2]),:])/2

  #Setup for Calculations
  Minv = sparse(inv(M)) #sparse(Minv) needed until update

  #Heat Equation Loop
  u,timeseries,ts=femheat_solve(FEMHeatIntegrator{islinear,typeof(alg),isstochastic,typeof(f),typeof(gD),typeof(gN),typeof(σ),eltype(u),typeof(u),typeof(node),typeof(area),typeof(t),typeof(D),typeof(Minv),typeof(A)}(N,NT,dt,t,Minv,D,A,freenode,f,gD,gN,u,node,elem,area,bdnode,mid,dirichlet,neumann,islinear,numvars,sqrtdt,σ,noisetype,numiters,save_everystep,timeseries,ts,solver,autodiff,method,show_trace,iterations,timeseries_steps,progressbar,progress_steps,progressbar_name))

  if typeof(analytic)!=Void #True Solution exists
    return(FEMSolution(timeseries,analytic(tspan[2],node),Du,ts,prob))
  else #No true solution
    return(FEMSolution(timeseries,ts,prob))
  end
end

"""
`quadfbasis(f,gD,gN,A,u,node,elem,area,bdnode,mid,N,NT,dirichlet,neumann,islinear,numvars;gNquad𝒪=2)`

Performs the order 2 quadrature to calculate the vector from the term ``<f,v>`` for linear elements.
"""
function quadfbasis(f,gD,gN,A,u,node,elem,area,bdnode,mid,N,NT,dirichlet,neumann,islinear,numvars;gNquad𝒪=2)
  b = zeros(area[1].*u) #size(bt1,2) == numvars #area is for units
  if islinear
    bt1 = area.*(f(mid[:,:,2])+f(mid[:,:,3]))/6
    bt2 = area.*(f(mid[:,:,3])+f(mid[:,:,1]))/6
    bt3 = area.*(f(mid[:,:,1])+f(mid[:,:,2]))/6
  else
    u1 = (u[vec(elem[:,2]),:]+u[vec(elem[:,3]),:])/2
    u2 = (u[vec(elem[:,3]),:]+u[vec(elem[:,1]),:])/2
    u3 = (u[vec(elem[:,1]),:]+u[vec(elem[:,2]),:])/2
    bt1 = area.*(f(mid[:,:,2],u2)+f(mid[:,:,3],u3))/6
    bt2 = area.*(f(mid[:,:,3],u3)+f(mid[:,:,1],u1))/6
    bt3 = area.*(f(mid[:,:,1],u1)+f(mid[:,:,2],u2))/6
  end

  for i = 1:numvars # accumarray the bt's
    for j = 1:NT
      b[elem[j,1],i] += bt1[j,i]
    end
    for j = 1:NT
      b[elem[j,2],i] += bt2[j,i]
    end
    for j = 1:NT
      b[elem[j,3],i] += bt3[j,i]
    end
  end


  if(!isempty(dirichlet))
    uz = zeros(b)
    uz[bdnode,:] = gD(node[bdnode,:])
    b = b-A*uz
  end

  if(!isempty(neumann))
    el = sqrt.(float(sum((node[neumann[:,1],:] - node[neumann[:,2],:]).^2,2)))
    λgN,ωgN = quadpts1(gNquad𝒪)
    ϕgN = λgN                # linear bases
    nQuadgN = size(λgN,1)
    ge = zeros(size(neumann,1),2,numvars) # Does this need units?

    for pp = 1:nQuadgN
        # quadrature points in the x-y coordinate
        ppxy = λgN[pp,1]*node[neumann[:,1],:] +
               λgN[pp,2]*node[neumann[:,2],:]
        gNp = gN(ppxy)
        for igN = 1:2, var = 1:numvars
            ge[:,igN,var] = ge[:,igN,var] + vec(ωgN[pp]*ϕgN[pp,igN]*gNp[:,var])
        end
    end
    ge = ge.*repeat(el,outer=[1,2,numvars]) # tuple in v0.5?

    for i=1:numvars
      b[:,i] = b[:,i] + accumarray(vec(neumann), vec(ge[:,i]),[N,1])
    end
  end
  if numvars == 1
    b = vec(b)
  end
  return(b)
end
