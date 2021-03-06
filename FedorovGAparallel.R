#-- Objective functions -----------------------------------------------------------
doptimality <- function(dm, design, lambda=0) {
  # calculates doptimality of design (and optionally penalizes distribution constraints)
  # params:
  # dm: DesignMatrix object containing attribute & constraint information
  # design: design matrix where columns are attributes and rows are patients
  # lambda: weight to penalize constraints.  lambda=0 means no distribution constraints
  # returns: d-efficiency metric
  
  # calculate slacks for the design
  dm$X <- design
  dm$update_slacks()
  
  objective <- (100 * det( t(design)%*%design )^(1/ncol(design)))/ nrow(design)
  # objective <- det( t(design)%*%design ) / nrow(design)
  penalty <- lambda*( sum(abs(unlist(dm$dslacks))) + lambda*(sum(abs(unlist(dm$islacks)))) )
  # this double-penalizes islacks b/c we really don't want impossible interactions
  return(objective - penalty)
}

sumfisherz <- function(dm, design, lambda=0) {
  # calculates the sum of the fisher z score of the absolute values of the correlation matrix
  # minimization objective function
  # params
  # dm: DesignMatrix object containing attribute & constraint information
  # design: design matrix where columns are attributes and rows are patients
  # lambda: weight to penalize constraints.  lambda=0 means no distribution constraints
  # design: design matrix where columns are attributes and rows are patients
  # returns correlation score
  
  # calculate slacks for the design
  dm$X <- design
  dm$update_slacks()
  
  r <- abs(cor(design))
  z <- .5*(log(1+r)/(1-r))
  objective <- sum(z[is.finite(z)])
  penalty <- lambda*( sum(abs(unlist(dm$dslacks))) + lambda*(sum(abs(unlist(dm$islacks)))) )
  return(objective + penalty)
}

#-- supporting functions ---------------------------------------
breed <- function(X, Y){
  # breeding function for genetic algorithm; approx 50/50 mix of parents
  # params:
    # X: design matrix (parent 1)
    # Y: design matrix (parent 2)
  # returns:
    # list(A,B) where A,B are child matrices of X,Y

  if (nrow(X) != nrow(Y)) {stop('Parents do not have equivalent rows')}
  if (ncol(X) != ncol(Y)) {stop('Parents do not have equivalent columns')}

  probsA <- runif(nrow(X),0,1)
  ax <- X[probsA > .5,]  # chromosomes from parent X
  ay <- Y[probsA <= .5,] # chromosomes from parent Y
  A <- rbind(ax,ay)

  probsB <- runif(nrow(X),0,1)
  bx <- X[probsB > .5,]  # chromosomes from parent X
  by <- Y[probsB <= .5,] # chromosomes from parent Y
  B <- rbind(bx,by)

  return(list(A,B))
} # end breed
mutate <- function(dm, X, alpha) {
  # mutation function for genetic algorithm
  # params:
    # dm: Design Matrix object
    # X: design matrix (chromosome to be mutated)
    # alpha: num 0-1 indicating likelihood for mutation (lower increases mutation)
  # returns: mutated matrix X

  for (i in 1:nrow(X)){
    # test whether to mutate row
    if (runif(1,0,1) >= alpha) {
      for (j in 1:ncol(X)) {
        # test whether to mutate cell
        if (runif(1,0,1) >= alpha) {
          # pick new value from permissible levels of attribute column
          X[i,j] <- sample(c(1:dm$levels[j]-1),1)
        } # end if j
      } # end for j
    } # end if i
  } # end for i

  return(X)
} # end mutate
cull <- function(elite, stock, children, pop, dir) {
  # function to reduce population back down to pop
  # params:
    # elite: list of elite design matrices to be preserved
    # stock: list of non-elite parents design matrices
    # children: list of new design matrices
    # pop: int, population size to achieve
  # returns: list (length pop) of best design matrices

  # combine stock and child lists
  fill <- append(stock,children)
  fill <- sorter(fill, dir)

  # find number of herd to fill after elites are kept
  nfill <- pop-length(elite)

  # generate new herd with elites and best of rest
  herd <- append(elite, head(fill, nfill))

  return(sorter(herd, dir))
} # end cull
sorter <- function(herd, dir) {
  # function to sort the herd based on objective function
  # params:
  # herd: list of (dval, matrix) tuples to be sorted
  # dir: direction to sort
  # returns: sorted herd
  
  if (dir=="min") {
    # value <- sapply(herd, function(x) x[[1]])
    # herd[order(value, decreasing=T)]
    return(herd[order(sapply(herd, function(x) x[[1]]), decreasing=F)])
  } else if (dir=="max") {
    # value <- sapply(herd, function(x) x[[1]])
    # herd[order(value, decreasing=T)]
    return(herd[order(sapply(herd, function(x) x[[1]]), decreasing=T)])
  } else {
    stop("Direction for objective function not defined")
  }
} # end sorter

#-- genetic algorithm --------------------------------------
gen_alg <- function(dm, pop, gens, test, lambda=0) {
  # genetic algorithm to find d-optimal design
  # params:
    # dm: Design Matrix object
    # pop: population size
    # gens: int, maximum number of generations
    # test: objective function to use
  # returns: optimal design

  #---- Package manager & housekeeper ----
  if(!"pacman" %in% installed.packages()[,"Package"]) install.packages("pacman")
  # load packages used
  pacman::p_load(doParallel, foreach)
  require(doParallel)
  #----

  ### check input params
  if (pop < 16){ stop('Suggested population minimum of 16') }
  if (gens < 100){ stop('Suggested generation minimum of 100') }

  if (test=="doptimality"){
    objfun <- doptimality
    dir <- "max"
  } else if (test=="sumfisherz") {
    objfun <- sumfisherz
    dir <- "min"
  } else {
    stop("Test value not in c('doptimality','sumfisherz')")
  }

  ### create parallel environment
  cl <- makeCluster(detectCores() - 1)
  registerDoParallel(cl)

  ### initialize variables
  alpha <- 0.4 # probability threshold; lower increases variation/mutation

  ### create herd (list of (dval, matrix) tuples)
  herd <- list()
  herd <- foreach(p=1:pop, .export=c("objfun","dm","lambda")) %dopar% { # don't need .combine param b/c results returned in list by default
    dm$generate()
    return(list(objfun(dm, dm$X, lambda), dm$X))
  } # end foreach
  
  herd <- sorter(herd, dir)
  top <- herd[[1]]

  ### pick elite designs to leave unchanged/unculled
  if (pop < 32) {
    nelite <- 2
  } else {
    nelite <- 4
  }

  g <- 1  # initialize iterator
  converge <- 0 # initialize convergence criteria counter
  while ((g < gens) && (converge < log2(gens))) {
    # stop if reach maximum generations OR
    # if difference between top designs remains small for some number of generations

    if ((pop %% 2) != 0) { nelite <- nelite-1} # adjust for odd population
    elite <- head(herd, nelite)
    stock <- tail(herd, -nelite)

    ### breed randomized pairs
    x <- sample(c(1:length(stock)))
    y <- sample(c(1:length(stock)))
    children <- list()
    children <- foreach(i=1:length(stock), .combine=c, .export=c("breed","stock")) %dopar% { #.combine = c to unlist kids
      if (x[i] != y[i]) { # no self-replication
        if (runif(1,0,1) >= alpha){
          # if test passed, breed & save children
          return( breed(stock[[ x[i] ]][[2]],stock[[ y[i] ]][[2]]) )
        }
      }
    } # end foreach

    ### mutation
    xmen <- list()
    xmen <- foreach(j=1:length(children), .export=c("mutate","dm","alpha")) %dopar% {
      if (runif(1,0,1) >= alpha) {
        # if test passed, mutate child
        return( mutate(dm, children[[j]], alpha) )
      } else {
        return(children[[j]])
      }
    } # end foreach
    rm(children)

    ### assess fitness
    children <- list()
    children <- foreach(k=1:length(xmen), .export=c("objfun","dm","lambda")) %dopar% {
      return(list(objfun(dm, xmen[[k]], lambda), xmen[[k]]))
    }
    rm(xmen)
    
    ### cull
    herd <- cull(elite, herd, children, pop, dir)

    ### updates
    g <- g+1
    if (dir == "max") {
      if ((herd[[1]][[1]]-top[[1]]) < 10e-6 ) {
        # maximizing, so change should be positive
        # if the change in objval (new - old) 0 and small pos number, system is converging
          # smallest possible change is 0 (i.e., same best design) b/c preserving elites
        # if converging, count as a converge step to potentially break out of while loop
        converge <- converge+1
      } else {
        # if not a converge step, reset converge coutner to 0
        converge <- 0
      }
    } else if (dir == "min") {
      if ((herd[[1]][[1]]-top[[1]]) > -10e-6 ) {
        # minimizing, so change should be negative
        # if the change in objval (new - old) small neg number and 0, system is converging
          # largest possible change is 0 (i.e., same best design) b/c preserving elites
        # if converging, count as a converge step to potentially break out of while loop
        converge <- converge+1
      } else {
        # if not a converge step, reset converge coutner to 0
        converge <- 0
      }
    }

    top <- herd[[1]]
  } # end while

  stopCluster(cl)
  print(paste("Convergence achieved in ",g," iterations"))
  return(herd[[1]])
} # end gen_alg
