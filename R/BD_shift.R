#--workflow--#
# * calculate BD windows for each fraction
# * calculate overlapping fractions


#' Adjusting BD range size if negative.
#'
#' If BD (buoyant density) range size is negative,
#' use BD_to_set value to set new BD_max. The \code{BD_to_set}
#' determines the \code{BD_max} if BD range is negative
#'
#' @param BD_range  BD range size
#' @param BD_min  Minimum BD value
#' @param BD_max  Maximum BD value
#' @param BD_to_set  Value added to BD_min to set new BD_max
#' @return New max BD value
#'
max_BD_range = function(BD_range, BD_min, BD_max, BD_to_set){
  # if BD_range is negative, use BD_to_set value to set new BD_max
  if(BD_range <= 0){
    return(BD_min + BD_to_set)
  } else {
    return(BD_max)
  }
}


#' Format phyloseq metadata for calculating BD range overlaps.
#'
#' @param physeq  Phyloseq object
#' @param ex  Expression for selecting the control samples to
#' compare to the non-control samples.
#'
#' @return a data.frame object of formatted metadata
#'
#' @examples
#' data(physeq)
#' ex = "Substrate=='12C-Con'"
#' metadata = format_metadata(physeq, ex)
#'
format_metadata = function(physeq,
                           ex = "Substrate=='12C-Con'"){
  metadata = phyloseq2df(physeq, table_func=sample_data)
  metadata$METADATA_ROWNAMES = rownames(metadata)

  stopifnot(all(c('Buoyant_density', 'Fraction') %in% colnames(metadata)))

  metadata = metadata %>%
    mutate_(IS__CONTROL = ex) %>%
    rename('BD_min' = Buoyant_density) %>%
    mutate(Fraction = Fraction %>% as.Num,
           BD_min = BD_min %>% as.Num) %>%
    arrange(BD_min) %>%
    group_by(IS__CONTROL) %>%
    mutate(BD_max = lead(BD_min),
           BD_max = ifelse(is.na(BD_max), BD_min, BD_max),
           BD_range = BD_max - BD_min) %>%
    group_by() %>%
    mutate(median_BD_range = median(BD_range, na.rm=T)) %>%
    ungroup() %>%
    mutate(BD_max = mapply(max_BD_range,
                           BD_range, BD_min, BD_max,
                           BD_to_set = median_BD_range)) %>%
    mutate(BD_range = BD_max - BD_min) %>%
    select(METADATA_ROWNAMES, IS__CONTROL,
           BD_min, BD_max, BD_range)

  return(metadata)
}


#' Calculate the percent overlap between two ranges (x & y).
#'
#' The fraction of overlap is relative to Range X (see examples).
#'
#' @param x.start  The start value for Range X
#' @param x.end  The end value for Range X
#' @param y.start  The start value for Range Y
#' @param x.end  The end value for Range Y
#'
#' @return the percent overlap of the ranges
#'
#' @examples
#'
#' x = perc_overlap(0, 1, 0, 0.5)
#' stopifnot(x == 50)
#' x = perc_overlap(0, 0.5, 0, 1)
#' stopifnot(x == 100)
#'
perc_overlap = function(x.start, x.end, y.start, y.end){
  x.len = abs(x.end - x.start)
  # largest start
  max.start = max(c(x.start, y.start))
  min.end = min(c(x.end, y.end))
  overlap = min.end - max.start
  overlap = ifelse(overlap <= 0, 0, overlap)
  perc_overlap = overlap / x.len * 100
  return(perc_overlap)
}


#' Calculate the BD range overlap of gradient fractions
#'
#'
#' @param metadata  Metdata data.frame object. See \code{format_metadata()}.
#'
#' @return a data.frame object of metadata with fraction BD overlaps
#'
#' @examples
#'
#' data(physeq)
#' ex = "Substrate=='12C-Con'"
#' metadata = format_metadata(physeq, ex)
#' m = fraction_overlap(metadata)
#' head(m)
#'
fraction_overlap = function(metadata){
  stopifnot(all(c('METADATA_ROWNAMES', 'IS__CONTROL') %in%
                  colnames(metadata)))

  meta_cont = filter(metadata, IS__CONTROL==TRUE)
  stopifnot(nrow(meta_cont) > 0)
  meta_treat = filter(metadata, IS__CONTROL==FALSE)
  stopifnot(nrow(meta_treat) > 0)

  # merging; calculating fraction overlap; filtering
  metadata_j = merge(meta_cont, meta_treat, by=NULL) %>%
    mutate(perc_overlap = mapply(perc_overlap,
                                 BD_min.x, BD_max.x,
                                 BD_min.y, BD_max.y)) %>%
     filter(perc_overlap > 0)
  stopifnot(nrow(metadata_j) > 0)

  return(metadata_j)
}

#' Filtering out non-relevant distances in distance matrix
#'
#' @param metadata  Metdata data.frame object. See \code{format_metadata()}.
#'
#' @return a data.frame object of metadata with fraction BD overlaps
#'
#' @examples
#'
#' data(physeq)
#' physeq_d = phyloseq::distance(physeq,
#'                              method='unifrac',
#'                              weighted=TRUE,
#'                              fast=TRUE,
#'                              normalized=FALSE)
#' physeq_d = parse_dist(physeq_d)
#' head(physeq_d)
#'
parse_dist = function(d){
  stopifnot(class(d)=='dist')

  df = d %>% as.matrix %>% as.data.frame
  df$sample = rownames(df)
  df = df %>% gather('sample.y', 'distance', -sample) %>%
    rename('sample.x' = sample) %>%
    filter(sample.x != sample.y)
  return(df)
}


#' Calculating weighted mean beta-diversities of overlapping gradient fractions.
#'
#' @param df_dist  Filtered distance matrix in data.frame format.
#' See \code{parse_dist()}
#'
#' @return a data.frame object of weighted mean distances
#'
#' @examples
#'
#' data(physeq)
#' physeq_d = phyloseq::distance(physeq,
#'                              method='unifrac',
#'                              weighted=TRUE,
#'                              fast=TRUE,
#'                              normalized=FALSE)
#' physeq_d = parse_dist(physeq_d)
#' wmean = overlap_wmean_dist(physeq_d)
#' head(wmean)
#'
overlap_wmean_dist = function(df_dist){
  # calculating weighted mean distance
  df_dist_s = df_dist %>%
    group_by(sample.x, BD_min.x) %>%
    mutate(n_over_fracs = n(),
           wmean_dist = weighted.mean(distance, perc_overlap)) %>%
    ungroup() %>%
    distinct(sample.x, wmean_dist, .keep_all=TRUE)
  return(df_dist_s)
}


#' Assessing the magnitude of BD shifts with 16S rRNA community
#' data by calculating the beta diversity between unlabeled control
#' and labeled treatment gradient fraction communities.
#'
#' This function is meant to compare 16S rRNA sequence communities
#' from many gradient fractions from 2 gradients: a labeled
#' treatment (eg., 13C-labeled DNA) and its corresponding unlabeled
#' control. First, the beta-diversity (e.g, Unifrac) is calculated
#' pairwise between fraction communities. Then, assuming that the
#' phyloseq \code{sample_data} contains buoyant density information
#' on each gradient fraction commumnity
#' (coded in the phyloseq object as 'Buoyant density'), the beta diversity
#' between each treatment gradient fraction relative to the overlapping
#' control fractions is set as the weighted mean of beta diversity
#' values for all overlapping fractions, with the % overlap used for
#' weighting.
#'
#' @param df_dist  phyloseq object
#' @param method  See phyloseq::distance
#' @param weighted  Weighted Unifrac (if calculating Unifrac)
#' @param fast  Fast calculation method
#' @param normalized  Normalized abundances
#' @param parallel  Calculate in parallel
#'
#' @return a data.frame object of weighted mean distances
#'
#' @export
#'
#' @examples
#'
#' data(physeq)
#' # Subsetting phyloseq by Substrate and Day
#' params = get_treatment_params(physeq, c('Substrate', 'Day'))
#' params = dplyr::filter(params, Substrate!='12C-Con')
#' ex = "(Substrate=='12C-Con' & Day=='${Day}') | (Substrate=='${Substrate}' & Day == '${Day}')"
#' physeq_l = phyloseq_subset(physeq, params, ex)
#' # Calculating BD_shift on 1 subset (use lapply to process full list)
#' wmean1 = BD_shift(physeq_l[[1]])
#' ggplot(wmean1, aes(BD_min.x, wmean_dist)) +
#'    geom_point()
#'
#' # Calculating BD_shift on all subsets
#' lapply(physeq_l, BD_shift)
#'
BD_shift = function(physeq, method='unifrac', weighted=TRUE,
                    fast=TRUE, normalized=FALSE, parallel=FALSE){
  # wrapper function
  ## formatting metadata
  metadata = format_metadata(physeq)
  ## fraction overlpa
  metadata = fraction_overlap(metadata)
  # Calculating distances
  physeq_d = phyloseq::distance(physeq,
                                method='unifrac',
                                weighted=TRUE,
                                fast=TRUE,
                                normalized=FALSE,
                                parallel=FALSE)
  physeq_d = parse_dist(physeq_d)

  # joining dataframes
  physeq_d = inner_join(physeq_d, metadata,
                        c('sample.x'='METADATA_ROWNAMES.x',
                          'sample.y'='METADATA_ROWNAMES.y'))

  # calculating weighted mean distance
  physeq_d_m = overlap_wmean_dist(physeq_d)
  return(physeq_d_m)
}
