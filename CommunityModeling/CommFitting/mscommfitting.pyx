# -*- coding: utf-8 -*-
#cython: language_level=3
from pandas import read_table, read_csv, DataFrame
from optlang import Variable, Constraint, Objective, Model
from optlang.symbolics import Zero
# from pprint import pprint
import numpy as np
# from cplex import Cplex
import cython
import os

def _variable_name(name, suffix, col, index):
    return '-'.join([name+suffix, col, index])

def _constraint_name(name, suffix, col, index):
    return '_'.join([name+suffix, col, index])

def _variance():
    pass

@cython.cclass
class MSCommFitting():
    def __init__(self):
        self.parameters: dict = {}; self.variables: dict = {}; self.constraints: dict= {}
        self.dataframes: dict = {}; self.signal_species: dict = {}
        
    @cython.ccall # ccall
    def load_data(self, media_name: str = None,      # the name of the media that defines the experimental conditions
                  phenotypes_csv_path: dict =None,   # the dictionary of index names for each paths to signal CSV data that will be fitted
                  signal_tsv_paths: dict = {},       # the dictionary of index names for each paths to signal TSV data that will be fitted
                  ):
        self.phenotypes_df = read_csv(phenotypes_csv_path)
        self.phenotypes_df.index = self.phenotypes_df['rxn']
        for col in ['rxn name', 'rxn']:
            self.phenotypes_df.drop(col, axis=1, inplace=True)
        
        self.species_phenotypes_bool_df = DataFrame(columns=self.phenotypes_df.columns)
        for path, name in signal_tsv_paths.items():
            signal = os.path.splitext(path)[0].split("_")[0]
            # define the signal dataframe
            self.signal_species[signal] = name
            self.dataframes[signal] = read_table(path).iloc[1::2]  # !!! is this the proper slice of data, or should the other set of values at each well/time be used?
            self.dataframes[signal].index = self.dataframes[signal]['Well']
            for col in ['Plate', 'Cycle', 'Well']:
                self.dataframes[signal].drop(col, axis=1, inplace=True)
            # convert the dataframe to a numpy array for greater efficiency
            self.dataframes[signal]: np.ndarray = np.array([
                self.dataframes[signal].index, self.dataframes[signal].columns, self.dataframes[signal].to_numpy()])
        
            # differentiate the phenotypes for each species
            self.parameters[signal]: dict = {}
            self.variables[signal+'__coef'], self.variables[signal+'__bio'], self.variables[signal+'__diff'] = {}, {}, {}
            self.constraints[signal+'__bioc'], self.constraints[signal+'__diffc'] = {}, {}
            if "OD" not in signal:
                self.species_phenotypes_bool_df.loc[signal]: np.ndarray[cython.int] = np.array([
                    1 if self.signal_species[signal] in pheno else 0 for pheno in self.phenotypes_df.columns])
    
    # def define_type_dictionaries():
    
    @cython.ccall # ccall
    def define_problem(self, conversion_rates={'cvt': 0, 'cvf': 0}, constraints={'cvc': {}}): 
        self.variables['bio_abundance'], self.variables['growth_rate'], self.variables['conc_met'], obj_coef = {}, {}, {}, {}
        self.constraints['dbc'], self.constraints['gc'], self.constraints['dcc'] = {}, {}, {}
        constraints: np.ndarray = np.zeros(1); variables: np.ndarray = np.zeros(1)
        self.problem = Model()
        
        self.parameters.update({
            "timestep_s": 600,      # Size of time step used in simulation in seconds
            "cvct": 1,      # Coefficient for the minimization of phenotype conversion to the stationary phase. 
            "cvcf": 1,      # Coefficient for the minimization of phenotype conversion from the stationary phase. 
            "bcv": 1,       # This is the highest fraction of biomass for a given strain that can change phenotypes in a single time step
            "cvmin": 0.1,     # This is the lowest value the limit on phenotype conversion goes, 
            "y": 1,         # Stoichiometry for interaction of strain k with metabolite i
            "v": 1,
        })
        self.parameters.update(conversion_rates)
        
        # define all biomass and growth variables
        index: str; col: str; name: str; strain: str; met: str; growth_stoich: cython.float = 0
        for strain in self.phenotypes_df:
            self.variables['b_'+strain], self.variables['g_'+strain] = {}, {}
            for name, df in self.dataframes.items():
                for index in df[0]:
                    self.variables['b_'+strain][index], self.variables['g_'+strain][index] = {}, {}
                    for col in df[1]:
                        self.variables['b_'+strain][index][col] = Variable(    # predicted biomass abundance
                            _variable_name("b_", strain, col, index), lb=0, ub=1000)  
                        self.variables['g_'+strain][index][col] = Variable(    # biomass growth
                            _variable_name("g_", strain, col, index), lb=0, ub=1000)   
                        variables = np.hstack([variables, [self.variables['b_'+strain][index][col], self.variables['g_'+strain][index][col]]])
                        
        # define metabolite variable/constraint
        for met, row in self.phenotypes_df.iterrows():
            self.variables["c_"+met], self.variables["c+1_"+met] = {}, {}
            for name, df in self.dataframes.items():
                for index in df[0]:
                    self.variables["c_"+met][index], self.variables["c+1_"+met][index] = {}, {}
                    self.constraints['dcc_'+met], self.constraints['dcc_'+met][index] = {}, {}
                    for col in df[1]:                    
                        # define biomass measurement conversion variables 
                        self.variables["c_"+met][index][col] = Variable(
                            _variable_name("c_", met, index, col), lb=0, ub=1000)    
                        self.variables["c+1_"+met][index][col] = Variable(
                            _variable_name("c+1_", met, index, col), lb=0, ub=1000)    
                        
                        # c_{met} + dt*sum_k^K() - c+1_{met} = 0
                        for growth_stoich in row.values:
                            for strain in self.phenotypes_df.columns:
                                growth_sum += growth_stoich*self.variables['g_'+strain][index][col]
                        self.constraints['dcc_'+met][index][col] = Constraint(
                            self.variables["c_"+met][index][col] 
                            + self.parameters['timestep_s']*growth_sum
                            - self.variables["c+1_"+met][index][col],
                            ub=0, lb=0, name=_constraint_name("dcc_", met, index, col))
                        
                        variables = np.hstack((variables, [self.variables["c_"+met][index][col], self.variables["c+1_"+met][index][col]]))
                        constraints = np.hstack((constraints, (self.constraints['dcc_'+met][index][col])))
                            
        # define predicted variables for each strain, time, and trial
        strain_independent = True
        for strain in self.phenotypes_df:
            self.variables['b+1_'+strain], self.variables['cvt_'+strain]  = {}, {}
            self.variables['cvf_'+strain], self.variables['v_'+strain] = {}, {}
            self.constraints['gc_'+strain], self.constraints['cvc_'+strain] = {}, {}
            self.constraints['dbc_'+strain] = {}
            for name, df in self.dataframes.items():
                self.variables[name+'__bio'], self.variables[name+'__diff'] = {}, {}
                self.constraints[name+'__bioc'], self.constraints[name+'__diffc'] = {}, {}
                last_column = False
                for r_index, index in enumerate(df[0]): 
                    self.variables['cvt_'+strain][index], self.variables['cvf_'+strain][index] = {}, {}
                    self.variables['v_'+strain][index], self.variables['b+1_'+strain][index] = {}, {}
                    self.variables[name+'__bio'][index], self.variables[name+'__diff'][index] = {}, {}
                    
                    self.constraints['gc_'+strain][index], self.constraints['cvc_'+strain][index] = {}, {}
                    self.constraints[name+'__bioc'][index], self.constraints[name+'__diffc'][index] = {}, {}
                    self.constraints['dbc_'+strain][index] = {}
                    
                    for c_index, col in enumerate(df[1]):
                        next_col = str(int(col)+1)
                        if next_col == len(df.columns):
                            last_column = True
                        # define variables
                        self.variables['v_'+strain][index][col] = Variable(    # predicted kinetic coefficient
                            _variable_name("v_", strain, index, col), lb=0, ub=1000)                          
                        self.variables['b+1_'+strain][index][next_col] = Variable(  # predicted biomass abundance
                            _variable_name("b+1_", strain, index, next_col), lb=0, ub=1000)      
                        self.variables['cvt_'+strain][index][col] = Variable(  # conversion rate to the stationary phase
                            _variable_name("cvt_", strain, index, col), lb=0, ub=100)   
                        self.variables['cvf_'+strain][index][col] = Variable(  # conversion from to the stationary phase
                            _variable_name("cvf_", strain, index, col), lb=0, ub=100)
                        
                        # g_{strain} - b_{strain}*v = 0
                        self.constraints['gc_'+strain][index][col] = Constraint(
                            self.variables['g_'+strain][index][col] 
                            - self.parameters['v']*self.variables['b_'+strain][index][col],  
                            _constraint_name("gc_", strain, index, col), lb=0, ub=0)
                        
                        # 0 <= -cvt + bcv*b_{strain} + cvmin
                        self.constraints["cvc_"+strain][index][col] = Constraint(
                            -self.variables['cvt_'+strain][index][col] 
                            + self.parameters['bcv']*self.variables['b_'+strain][index][col] 
                            + self.parameters['cvmin'],
                            _constraint_name("cvc_", strain, index, col), lb=0, ub=None)
                        
                        if strain_independent:                            
                            # define variables
                            self.variables[name+'__conversion'] = Variable(name+'__conversion', lb=0, ub=1000)
                            self.variables[name+'__bio'][index][col] = Variable(      
                                _variable_name(name, '__bio', index, col), lb=0, ub=1000)
                            self.variables[name+'__diff'][index][col] = Variable(       
                                _variable_name(name, '__diff', index, col), lb=-100, ub=100)
   
                            # {name}__conversion*datum = {name}__bio
                            self.constraints[name+'__bioc'][index][col] = Constraint(
                                 self.variables[name+'__conversion']*df[3][r_index, c_index] - self.variables[name+'__bio'][index][col], 
                                 name=_constraint_name(name, '__bioc', index, col), lb=0, ub=0)
                            
                            # add variables, constraints, and objective coefficients
                            obj_coef[self.variables[name+'__diff'][index][col]] = 1
                            variables = np.hstack((variables, [self.variables[name+'__bio'][index][col], 
                                self.variables[name+'__diff'][index][col], self.variables[name+'__conversion']]))
                            constraints = np.hstack((constraints, [self.constraints[name+'__bioc'][index][col]]))
                        
                        # {name}__bio - sum_k^K(signal_bool*{name}__conversion*datum) - {name}__diff = 0
                        total_biomass = signal_sum = from_sum = to_sum = 0
                        for strain in self.phenotypes_df:
                            total_biomass += self.variables["b_"+strain][index][col]
                            from_sum += self.species_phenotypes_bool_df.loc[name, strain]*self.variables['cvf_'+strain][index][col]
                            to_sum += self.species_phenotypes_bool_df.loc[name, strain]*self.variables['cvt_'+strain][index][col]
                            if 'OD' not in name:  # the OD strain has a different constraint, hence it is strain-dependent
                                signal_sum += self.species_phenotypes_bool_df.loc[name, strain]*self.variables["b_"+strain][index][col]
                        for name, dic in {name+'__diffc':self.constraints[name+'__diffc'][index], 
                                    name+'__bio':self.variables[name+'__bio'][index], 
                                    name+'__diff':self.variables[name+'__diff'][index]}.items():
                            if col not in dic:
                                print(f'{col} is not defined in {name}.')
                        self.constraints[name+'__diffc'][index][col] = Constraint(   
                             self.variables[name+'__bio'][index][col]-signal_sum
                             - self.variables[name+'__diff'][index][col], 
                             name=_constraint_name(name, '__diffc', index, col), lb=0, ub=0)
                        
                        if "stationary" in strain:  
                            # b_{strain} - sum_k^K(pheno_bool*cvf) + sum_k^K(pheno_bool*cvt) - b+1_{strain} = 0
                            self.constraints['dbc_'+strain][index][col] = Constraint(
                                self.variables['b_'+strain][index][col] - from_sum + to_sum - self.variables['b+1_'+strain][index][next_col],
                                ub=0, lb=0, name=_constraint_name("dbc_", strain, index, col))
                        else:
                            # -b_{strain} + dt*g_{strain} + cvf - cvt - b+1_{strain} = 0
                            self.constraints['dbc_'+strain][index][col] = Constraint(
                                self.variables['b_'+strain][index][col]
                                + self.parameters['timestep_s']*self.variables['g_'+strain][index][col]
                                + self.variables['cvf_'+strain][index][col] - self.variables['cvt_'+strain][index][col]
                                - self.variables['b+1_'+strain][index][next_col],
                                ub=0, lb=0, name=_constraint_name("dbc_", strain, index, col))
                            
                        # assemble variables, constraints, and objective coefficients
                        variables = np.hstack((variables, [self.variables['cvt_'+strain][index][col], self.variables['cvf_'+strain][index][col]]))
                        constraints = np.hstack((constraints, [self.constraints['cvc_'+strain][index][col], self.constraints['gc_'+strain][index][col],
                                            self.constraints[name+'__diffc'][index][col], self.constraints['dbc_'+strain][index][col]]))
                        obj_coef.update({self.variables['cvt_'+strain][index][col]*self.parameters['cvct']: -1,
                                         self.variables['cvf_'+strain][index][col]*self.parameters['cvcf']: -1})
                        if last_column:
                            break
                    if last_column:
                        break
            strain_independent = False
              
        # construct the problem
        self.problem.add(np.concatenate((constraints, variables)))
        self.problem.objective = Objective(Zero, direction="min")
        self.problem.objective.set_linear_coefficients(obj_coef)
                
    def _export(self, filename=None, print_lp=True):
        if filename:
            with open(filename, 'w') as out:
                out.writelines(
                    ['|'.join(['parameter', param, content+": "+str(self.parameters[param][content])]) for param, content in self.parameters.items()]
                    + ['|'.join(['variable', var, content+": "+str(self.parameters[var][content])]) for var, content in self.variables.items()]
                    + ['|'.join(['constant', const, content+": "+str(self.parameters[const][content])]) for const, content in self.constants.items()])
        if print_lp:
            with open('mscommfitting.lp', 'w') as lp:
                lp.write(self.problem.solver)