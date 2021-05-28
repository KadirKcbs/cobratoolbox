function [exchanges, netProduction, netUptake, presol, inFesMat] = microbiotaModelSimulator(resPath, exMets, sampNames, dietFilePath, hostPath, hostBiomassRxn, hostBiomassRxnFlux, numWorkers, rDiet, pDiet, saveConstrModels, computeProfiles, includeHumanMets, lowerBMBound, repeatSim, adaptMedium)

% This function is called from the MgPipe pipeline. Its purpose is to apply
% different diets (according to the user's input) to the microbiota models
% and run simulations computing FVAs on exchanges reactions of the microbiota
% models. The output is saved in multiple .mat objects. Intermediate saving
% checkpoints are present.
%
% USAGE:
%
%   [exchanges, netProduction, netUptake, presol, inFesMath] = microbiotaModelSimulator(resPath, exMets, sampNames, dietFilePath, hostPath, hostBiomassRxn, hostBiomassRxnFlux, numWorkers, rDiet, pDiet, saveConstrModels, computeProfiles, includeHumanMets, lowerBMBound, repeatSim, adaptMedium)
%
% INPUTS:
%    resPath:            char with path of directory where results are saved
%    exMets:             cell array with all unique extracellular metabolites
%                        contained in the models
%    sampNames:          cell array with names of individuals in the study
%    dietFilePath:       path to and name of the text file with dietary information
%    hostPath:           char with path to host model, e.g., Recon3D (default: empty)
%    hostBiomassRxn:     char with name of biomass reaction in host (default: empty)
%    hostBiomassRxnFlux: double with the desired upper bound on flux through the host
%                        biomass reaction (default: 1)
%    numWorkers:         integer indicating the number of cores to use for parallelization
%    rDiet:              boolean indicating if to simulate a rich diet
%    pDiet:              boolean indicating if a personalized diet
%                        is available and should be simulated
%    saveConstrModels:   boolean indicating if models with imposed
%                        constraints are saved externally
%    computeProfiles:    boolean defining whether flux variability analysis to
%                        compute the metabolic profiles should be performed.
%    includeHumanMets:   boolean indicating if human-derived metabolites
%                        present in the gut should be provexchangesed to the models (default: true)
%    lowerBMBound        Minimal amount of community biomass in mmol/person/day enforced (default=0.4)
%    repeatSim:          boolean defining if simulations should be repeated and previous results
%                        overwritten (default=false)
%    adaptMedium:        boolean indicating if the medium should be adapted through the
%                        adaptVMHDietToAGORA function or used as is (default=true)
%
% OUTPUTS:
%    exchanges:          cell array with list of all unique Exchanges to diet/
%                        fecal compartment
%    netProduction:              cell array containing FVA values for maximal uptake
%                        and secretion for setup lumen / diet exchanges
%    netUptake:               cell array containing FVA values for minimal uptake
%                        and secretion for setup lumen / diet exchanges
%    presol              array containing values of microbiota models
%                        objective function
%    inFesMat            cell array with names of infeasible microbiota models
%
% .. Author: Federico Baldini, 2017-2018
%            Almut Heinken, 03/2021: simplified inputs

% set a solver if not done yet
global CBT_LP_SOLVER
solver = CBT_LP_SOLVER;
if isempty(solver)
    initCobraToolbox(false); %Don't update the toolbox automatically
end

for i=1:length(exMets)
    exchanges{i,1} = ['EX_' exMets{i}];
end
exchanges = regexprep(exchanges, '\[e\]', '\[fe\]');
exchanges = setdiff(exchanges, 'EX_biomass[fe]', 'stable');

% reload existing simulation results by default
if ~exist('repeatSim', 'var')
    repeatSim=0;
end

% define whether simulations should be skipped
skipSim=0;
if isfile(strcat(resPath, 'simRes.mat'))
    load(strcat(resPath, 'simRes.mat'))
    skipSim=1;
    for i=1:size(presol,1)
        % check for all feasible models that simulations were properly
        % executed
        if presol{i,2} > lowerBMBound
            if isempty(netProduction{2,i}(:,2))
                % feasible model was skipped, repeat simulations
                skipSim=0;
            end
            vals=netProduction{2,i}(find(~cellfun(@isempty,(netProduction{2,i}(:,2)))),2);
            if abs(sum(cell2mat(vals)))<0.000001
                % feasible model was skipped, repeat simulations
                skipSim=0;
            end
        end
    end
    % verify that every simulation result is correct
end

% if repeatSim is true, simulations will be repeated in any case
if repeatSim==1
    skipSim=0;
end

if skipSim==1
    s = 'simulations already done, file found: loading from resPath';
    disp(s)
else
    % Cell array to store results
    netProduction = cell(3, length(sampNames));
    netUptake = cell(3, length(sampNames));
    inFesMat = {};
    presol = {};
    
    % Auto load for crashed simulations if desired
    if repeatSim==0
        mapP = detectOutput(resPath, 'intRes.mat');
        if isempty(mapP)
            startIter = 1;
        else
            s = 'simulation checkpoint file found: recovering crashed simulation';
            disp(s)
            load(strcat(resPath, 'intRes.mat'))
            
            % Detecting when execution halted
            for o = 1:length(netProduction(2, :))
                if isempty(netProduction{2, o}) == 0
                    t = o;
                end
            end
            startIter = t + 2;
        end
    elseif repeatSim==1
        startIter = 1;
    end
    
    % if simRes file already exists: some simulations may have been
    % incorrectly executed and need to repeat
    if isfile(strcat(resPath, 'simRes.mat'))
        load(strcat(resPath, 'simRes.mat'))
    end
    
    % End of Auto load for crashed simulations
    
    if ~exist('lowerBMBound','var')
        lowerBMBound=0.4;
    end
    
    % determine human-derived metabolites present in the gut: primary bile
    % acexchangess, amines, mucins, host glycans
    if includeHumanMets
        HumanMets={'gchola','-10';'tdchola','-10';'tchola','-10';'dgchol','-10';'34dhphe','-10';'5htrp','-10';'Lkynr','-10';'f1a','-1';'gncore1','-1';'gncore2','-1';'dsT_antigen','-1';'sTn_antigen','-1';'core8','-1';'core7','-1';'core5','-1';'core4','-1';'ha','-1';'cspg_a','-1';'cspg_b','-1';'cspg_c','-1';'cspg_d','-1';'cspg_e','-1';'hspg','-1'};
    end
    
    % Starting personalized simulations
    for k = startIter:length(sampNames)
        doSim=1;
        % check first if simulations already exist and were done properly
        if ~isempty(netProduction{2,k})
            vals=netProduction{2,k}(find(~cellfun(@isempty,(netProduction{2,k}(:,2)))),2);
            if abs(sum(cell2mat(vals)))> 0.1
                doSim=0;
            end
        end
        if doSim==1
            % simulations either not done yet or done incorrectly -> go
            sampleID = sampNames{k,1};
            if ~isempty(hostPath)
                microbiota_model=readCbModel(strcat('host_microbiota_model_samp_', sampleID,'.mat'));
            else
                microbiota_model=readCbModel(strcat('microbiota_model_samp_', sampleID,'.mat'));
            end
            model = microbiota_model;
            for j = 1:length(model.rxns)
                if strfind(model.rxns{j}, 'biomass')
                    model.lb(j) = 0;
                end
            end
            
            % adapt constraints
            BiomassNumber=find(strcmp(model.rxns,'communityBiomass'));
            Components = model.mets(find(model.S(:, BiomassNumber)));
            Components = strrep(Components,'_biomass[c]','');
            for j=1:length(Components)
                % remove constraints on demand reactions to prevent infeasibilities
                findDm= model.rxns(find(strncmp(model.rxns,[Components{j} '_DM_'],length([Components{j} '_DM_']))));
                model = changeRxnBounds(model, findDm, 0, 'l');
                % constrain flux through sink reactions
                findSink= model.rxns(find(strncmp(model.rxns,[Components{j} '_sink_'],length([Components{j} '_sink_']))));
                model = changeRxnBounds(model, findSink, -1, 'l');
            end
            
            model = changeObjective(model, 'EX_microbeBiomass[fe]');
            AllRxn = model.rxns;
            RxnInd = find(cellfun(@(x) ~isempty(strfind(x, '[d]')), AllRxn));
            EXrxn = model.rxns(RxnInd);
            EXrxn = regexprep(EXrxn, 'EX_', 'Diet_EX_');
            model.rxns(RxnInd) = EXrxn;
            model = changeRxnBounds(model, 'communityBiomass', lowerBMBound, 'l');
            model = changeRxnBounds(model, 'communityBiomass', 1, 'u');
            model=changeRxnBounds(model,model.rxns(strmatch('UFEt_',model.rxns)),1000000,'u');
            model=changeRxnBounds(model,model.rxns(strmatch('DUt_',model.rxns)),1000000,'u');
            model=changeRxnBounds(model,model.rxns(strmatch('EX_',model.rxns)),1000000,'u');
            
            % set constraints on host exchanges if present
            if ~isempty(hostBiomassRxn)
                hostEXrxns=find(strncmp(model.rxns,'Host_EX_',8));
                model=changeRxnBounds(model,model.rxns(hostEXrxns),0,'l');
                % constrain blood exchanges but make exceptions for metabolites that should be taken up from
                % blood
                takeupExch={'h2o','hco3','o2'};
                takeupExch=strcat('Host_EX_', takeupExch, '[e]b');
                model=changeRxnBounds(model,takeupExch,-100,'l');
                % close internal exchanges except for human metabolites known
                % to be found in the intestine
                hostIEXrxns=find(strncmp(model.rxns,'Host_IEX_',9));
                model=changeRxnBounds(model,model.rxns(hostIEXrxns),0,'l');
                takeupExch={'gchola','tdchola','tchola','dgchol','34dhphe','5htrp','Lkynr','f1a','gncore1','gncore2','dsT_antigen','sTn_antigen','core8','core7','core5','core4','ha','cspg_a','cspg_b','cspg_c','cspg_d','cspg_e','hspg'};
                takeupExch=strcat('Host_IEX_', takeupExch, '[u]tr');
                model=changeRxnBounds(model,takeupExch,-1000,'l');
                % set a minimum and a limit for flux through host biomass
                % reaction
                model=changeRxnBounds(model,['Host_' hostBiomassRxn],0.001,'l');
                model=changeRxnBounds(model,['Host_' hostBiomassRxn],hostBiomassRxnFlux,'u');
            end
            
            % set parallel pool if no longer active
            if numWorkers > 1
                poolobj = gcp('nocreate');
                if isempty(poolobj)
                    parpool(numWorkers)
                end
            end
            
            solution_allOpen = solveCobraLP(buildLPproblemFromModel(model));
            % solution_allOpen=solveCobraLPCPLEX(model,2,0,0,[],0);
            if solution_allOpen.stat==0
                warning('Presolve detected one or more infeasible models. Please check InFesMat object !')
                inFesMat{k, 1} = model.name;
            else
                presol{k, 1} = solution_allOpen.obj;
                AllRxn = model.rxns;
                FecalInd  = find(cellfun(@(x) ~isempty(strfind(x,'[fe]')),AllRxn));
                DietInd  = find(cellfun(@(x) ~isempty(strfind(x,'[d]')),AllRxn));
                FecalRxn = AllRxn(FecalInd);
                FecalRxn=setdiff(FecalRxn,'EX_microbeBiomass[fe]','stable');
                DietRxn = AllRxn(DietInd);
                if rDiet==1 && computeProfiles
                    [minFlux,maxFlux]=guidedSim(model,FecalRxn);
                    minFluxFecal = minFlux;
                    maxFluxFecal = maxFlux;
                    [minFlux,maxFlux]=guidedSim(model,DietRxn);
                    minFluxDiet = minFlux;
                    maxFluxDiet = maxFlux;
                    netProduction{1,k}=exchanges;
                    netUptake{1,k}=exchanges;
                    for i =1:length(FecalRxn)
                        [truefalse, index] = ismember(FecalRxn(i), exchanges);
                        netProduction{1,k}{index,2} = minFluxDiet(i,1);
                        netProduction{1,k}{index,3} = maxFluxFecal(i,1);
                        netUptake{1,k}{index,2} = maxFluxDiet(i,1);
                        netUptake{1,k}{index,3} = minFluxFecal(i,1);
                    end
                end
                if rDiet==1 && saveConstrModels
                    microbiota_model=model;
                    mkdir([resPath filesep 'Rich'])
                    save([resPath filesep 'Rich' filesep 'microbiota_model_' sampleID '.mat'],'microbiota_model')
                end
                
                % Using input diet
                
                model_sd=model;
                if adaptMedium
                    [diet] = adaptVMHDietToAGORA(dietFilePath,'Microbiota');
                else
                    diet = readtable(dietFilePath, 'Delimiter', '\t');  % load the text file with the diet
                    diet = table2cell(diet);
                    for j = 1:length(diet)
                        diet{j, 2} = num2str(-(diet{j, 2}));
                    end
                end
                [model_sd] = useDiet(model_sd, diet,0);
                
                if includeHumanMets
                    % add the human metabolites
                    for l=1:length(HumanMets)
                        model_sd=changeRxnBounds(model_sd,strcat('Diet_EX_',HumanMets{l},'[d]'),str2num(HumanMets{l,2}),'l');
                    end
                end
                
                if exist('unfre') ==1 %option to directly add other essential nutrients
                    warning('Feasibility forced with addition of essential nutrients')
                    model_sd=changeRxnBounds(model_sd, unfre,-0.1,'l');
                end
                solution_sDiet=solveCobraLP(buildLPproblemFromModel(model_sd));
                % solution_sDiet=solveCobraLPCPLEX(model_sd,2,0,0,[],0);
                presol{k,2}=solution_sDiet.obj;
                if solution_sDiet.stat==0
                    warning('Presolve detected one or more infeasible models. Please check InFesMat object !')
                    inFesMat{k,2}= model.name;
                else
                    if computeProfiles
                        [minFlux,maxFlux]=guidedSim(model_sd,FecalRxn);
                        sma=maxFlux;
                        sma2=minFlux;
                        [minFlux,maxFlux]=guidedSim(model_sd,DietRxn);
                        smi=minFlux;
                        smi2=maxFlux;
                        maxFlux=sma;
                        minFlux=smi;
                        
                        netProduction{2,k}=exchanges;
                        netUptake{2,k}=exchanges;
                        for i =1:length(FecalRxn)
                            [truefalse, index] = ismember(FecalRxn(i), exchanges);
                            netProduction{2,k}{index,2}=minFlux(i,1);
                            netProduction{2,k}{index,3}=maxFlux(i,1);
                            netUptake{2,k}{index,2}=smi2(i,1);
                            netUptake{2,k}{index,3}=sma2(i,1);
                        end
                    end
                    
                    if saveConstrModels
                        microbiota_model=model_sd;
                        mkdir([resPath filesep 'Diet'])
                        save([resPath filesep 'Diet' filesep 'microbiota_model_diet_' sampleID '.mat'],'microbiota_model')
                    end
                    
                    save(strcat(resPath,'intRes.mat'),'netProduction','presol','inFesMat', 'netUptake')
                    
                    % Using personalized diet not documented in MgPipe and bug checked yet!!!!
                    
                    if pDiet==1
                        model_pd=model;
                        [Numbers, Strings] = xlsread(strcat(abundancepath,fileNameDiets));
                        % diet exchange reactions
                        DietNames = Strings(2:end,1);
                        % Diet exchanges for all individuals
                        Diets(:,k) = cellstr(num2str((Numbers(1:end,k))));
                        Dietexchanges = {DietNames{:,1} ; Diets{:,k}}';
                        Dietexchanges = regexprep(Dietexchanges,'EX_','Diet_EX_');
                        Dietexchanges = regexprep(Dietexchanges,'\(e\)','\[d\]');
                        
                        model_pd = setDietConstraints(model_pd,Dietexchanges);
                        
                        if includeHumanMets
                            % add the human metabolites
                            for l=1:length(HumanMets)
                                model_pd=changeRxnBounds(model_pd,strcat('Diet_EX_',HumanMets{l},'[d]'),str2num(HumanMets{l,2}),'l');
                            end
                        end
                        
                        solution_pdiet=solveCobraLP(buildLPproblemFromModel(model_pd));
                        %solution_pdiet=solveCobraLPCPLEX(model_pd,2,0,0,[],0);
                        presol{k,3}=solution_pdiet.obj;
                        if isnan(solution_pdiet.obj)
                            warning('Presolve detected one or more infeasible models. Please check InFesMat object !')
                            inFesMat{k,3}= model.name;
                        else
                            
                            if computeProfiles
                                [minFlux,maxFlux]=guidedSim(model_pd,FecalRxn);
                                sma=maxFlux;
                                [minFlux,maxFlux]=guidedSim(model_pd,DietRxn);
                                smi=minFlux;
                                maxFlux=sma;
                                minFlux=smi;
                                netProduction{3,k}=exchanges;
                                for i = 1:length(FecalRxn)
                                    [truefalse, index] = ismember(FecalRxn(i), exchanges);
                                    netProduction{3,k}{index,2}=minFlux(i,1);
                                    netProduction{3,k}{index,3}=maxFlux(i,1);
                                end
                            end
                            
                            if saveConstrModels
                                microbiota_model=model_pd;
                                mkdir(strcat(resPath,'Personalized'))
                                save([resPath filesep 'Personalized' filesep 'microbiota_model_pDiet_' sampleID '.mat'],'microbiota_model')
                            end
                            
                        end
                    end
                end
            end
        end
    end
    
    % Saving all output of simulations
    save(strcat(resPath,'simRes.mat'),'netProduction','presol','inFesMat', 'netUptake')
end

end
