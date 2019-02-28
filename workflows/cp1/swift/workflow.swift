
/*
  XCORR SWIFT
  Main cross-correlation workflow
*/

import files;
import io;
import python;
import unix;
import sys;
import string;
import EQR;
import location;
import math;

string FRAMEWORK = "keras";

string xcorr_root = getenv("XCORR_ROOT");
string preprocess_rnaseq = getenv("PREPROP_RNASEQ");
string emews_root = getenv("EMEWS_PROJECT_ROOT");
string turbine_output = getenv("TURBINE_OUTPUT");

printf("TURBINE_OUTPUT: " + turbine_output);

string db_file = argv("db_file");
string cache_dir = argv("cache_dir");


string resident_work_ranks = getenv("RESIDENT_WORK_RANKS");
string r_ranks[] = split(resident_work_ranks,",");
int propose_points = toint(argv("pp", "3"));
int max_budget = toint(argv("mb", "110"));
int max_iterations = toint(argv("it", "5"));
int design_size = toint(argv("ds", "10"));
string param_set = argv("param_set_file");
string exp_id = argv("exp_id");
int benchmark_timeout = toint(argv("benchmark_timeout", "-1"));
string restart_file = argv("restart_file", "DISABLED");
string r_file = argv("r_file", "mlrMBO1.R");

string restart_number = argv("restart_number", "1");
string site = argv("site");

if (restart_file != "DISABLED") {
  assert(restart_number != "1",
         "If you are restarting, you must increment restart_number!");
}


string studies[] = ["CCLE", "CTRP"]; //, "gCSI"]; //file_lines(input(xcorr_root + "/studies.txt"));
string rna_seq_data = "%s/test_data/combined_rnaseq_data_lincs1000_%s.bz2" % (xcorr_root, preprocess_rnaseq);
string drug_response_data = xcorr_root + "/test_data/rescaled_combined_single_drug_growth_100K";
int cutoffs[][] = [[200, 100]]; //,
                 //  [100, 50],
                 //  [400, 200],
                  //  [200, 50],
                  //  [400, 50],
                  //  [400, 100]];

string update_param_template =
"""
import json

params = json.loads('%s')
# --cell_feature_subset_path $FEATURES --train_sources $STUDY1 --preprocess_rnaseq $PREPROP_RNASEQ
params['cell_feature_subset_path'] = '%s'
params['train_sources'] = '%s'
params['preprocess_rnaseq'] = '%s'

import os
cf = os.path.basename(params['cell_feature_subset_path'])
idx = cf.rfind('.')
if idx != -1:
  cf = [:idx]

params['cache'] = '%s/{}_cache'.format(cf)
params_json = json.dumps(params)
""";


(string record_id)
compute_feature_correlation(string study1, string study2,
                            int corr_cutoff, int xcorr_cutoff,
                            string features_file)
{
  log_corr_template =
"""
from xcorr_db import xcorr_db, setup_db

global DB
DB = setup_db('%s')

features = DB.scan_features_file('%s')
record_id = DB.insert_xcorr_record(studies=[ '%s', '%s' ],
                       features=features,
                       cutoff_corr=%d, cutoff_xcorr=%d)
""";

  xcorr_template =
"""
rna_seq_data = '%s'
drug_response_data = '%s'
study1 = '%s'
study2 = '%s'
correlation_cutoff = %d
cross_correlation_cutoff = %d
features_file = '%s'

import uno_xcorr

if uno_xcorr.gene_df is None:
    uno_xcorr.init_uno_xcorr(rna_seq_data, drug_response_data)

uno_xcorr.coxen_feature_selection(study1, study2,
                                  correlation_cutoff,
                                  cross_correlation_cutoff,
                                  output_file=features_file)
""";

  log_code = log_corr_template % (db_file, features_file, study1, study2,
                                  corr_cutoff, xcorr_cutoff);

  xcorr_code = xcorr_template % (rna_seq_data, drug_response_data,
                                 study1, study2,
                                 corr_cutoff, xcorr_cutoff,
                                 features_file);

  python_persist(xcorr_code) =>
  record_id = python_persist(log_code, "str(record_id)");
}

(void v) loop(int init_prio, int modulo_prio, location ME, string feature_file, string train_source) {

  for (boolean b = true, int i = 1;
       b;
       b=c, i = i + 1)
  {
    string params =  EQR_get(ME);
    boolean c;

    if (params == "DONE")
    {
      string finals =  EQR_get(ME);
      // TODO if appropriate
      // split finals string and join with "\\n"
      // e.g. finals is a ";" separated string and we want each
      // element on its own line:
      // multi_line_finals = join(split(finals, ";"), "\\n");
      string fname = "%s/final_res.Rds" % (turbine_output);
      printf("See results in %s", fname) =>
      // printf("Results: %s", finals) =>
      v = propagate(finals) =>
      c = false;
    }
    else if (params == "EQR_ABORT")
    {
      printf("EQR aborted: see output for R error") =>
      string why = EQR_get(ME);
      printf("%s", why) =>
          // v = propagate(why) =>
      c = false;
    }
    else
    {
        int prio = init_prio - i * modulo_prio;
        string param_array[] = split(params, ";");
        string results[];
        foreach param, j in param_array
        {
            param_code = update_param_template % (param, feature_file, train_source, preprocess_rnaseq,
                cache_dir);
            updated_param = python_persist(param_code, "params_json");
            // TODO log run with record_id in DB
            //printf("Updated Params: %s", updated_param);
            // use init_prio as the id of this mlrMBO
            results[j] = obj_prio(updated_param,
                             "%00i_%00i_%000i_%0000i" % (abs_integer(init_prio), restart_number,i,j), prio);
        }
        string result = join(results, ";");
        // printf(result);
        EQR_put(ME, result) => c = true;
    }
  }
}


// These must agree with the arguments to the objective function in mlrMBO.R,
// except param.set.file is removed and processed by the mlrMBO.R algorithm wrapper.
string algo_params_template =
"""
param.set.file='%s',
max.budget = %d,
max.iterations = %d,
design.size=%d,
propose.points=%d,
restart.file = '%s'
""";

// (void o) start(int ME_rank, string record_id, string feature_file, string study1) {
//   printf("starting %s, %s, %s on %i", record_id, feature_file, study1, ME_rank) =>
//   o = propagate();
// }

(void o) start(int init_prio, int modulo_prio, int ME_rank, string record_id, string feature_file, string study1) {
    location ME = locationFromRank(ME_rank);

    // algo_params is the string of parameters used to initialize the
    // R algorithm. We pass these as R code: a comma separated string
    // of variable=value assignments.
    string algo_params = algo_params_template %
        (param_set, max_budget, max_iterations, design_size,
         propose_points, restart_file);
    string algorithm = emews_root+"/../common/R/"+r_file;
    EQR_init_script(ME, algorithm) =>
    EQR_get(ME) =>
    EQR_put(ME, algo_params) =>
    loop(init_prio, modulo_prio, ME, feature_file, study1) => {
        EQR_stop(ME) =>
        EQR_delete_R(ME);
        o = propagate();
    }
}

main() {
  string params[][];
  foreach study1 in studies
  {
    foreach study2 in studies
    {

      if (study1 != study2)
      {
        foreach cutoff in cutoffs
        {
          printf("Study1: %s, Study2: %s, cc: %d, ccc: %d",
                study1, study2, cutoff[0], cutoff[1]);
          fname = "%s/data/%s_%s_%d_%d_features.txt" %
            (turbine_output, study1, study2, cutoff[0], cutoff[1]);

          string record_id = compute_feature_correlation(study1, study2, cutoff[0], cutoff[1], fname);
          int h = hash(record_id);
          params[h] = [record_id, fname, study1];
        }
      }
    }
  }

  int ME_ranks[];
  foreach r_rank, i in r_ranks
  {
    ME_ranks[i] = toint(r_rank);
  }

  assert(size(ME_ranks) == size(params), "Number of ME ranks must equal number of xcorrs");
  int keys[] = keys_integer(params);

  int modulo_prio = size(ME_ranks);
  foreach hash_index, r in keys
  {
    string ps[] = params[hash_index];
    int rank = ME_ranks[r];
    // rank, record_id, feature file name, study1 name
    start(-r - 1, modulo_prio, rank, ps[0], ps[1], ps[2]);
  }
}