% The COBRAToolbox: testGenerateRules.m
%
% Purpose:
%     - testGenerateRules tests generateRules
%
% Authors:
%     - Initial Version: Uri David Akavia - August 2017

global CBTDIR

% save the current path
currentDir = pwd;

% initialize the test
fileDir = fileparts(which('testGenerateRules'));
cd(fileDir);

modelsToTry = {'Acidaminococcus_intestini_RyC_MR95.mat', 'Acidaminococcus_sp_D21.mat', 'Recon1.0model.mat', 'Recon2.v04.mat', 'ecoli_core_model.mat', 'modelReg.mat'};

for i=1:length(modelsToTry)
    model = getDistributedModel(modelsToTry{i});
    fprintf('Beginning model %s\n', modelsToTry{i});

    model2 = generateRules(model);
    model.rules = strrep(model.rules, '  ', ' ');
    model.rules = strrep(model.rules, ' )', ')');
    model.rules = strrep(model.rules, '( ', '(');

    % fix for Recon2
    if strcmp(modelsToTry{i}, 'Recon2.v04.mat')
        model.rules(2240) = {'(x(2)) | (x(4)) | (x(3))'}; % '(26.1) or (314.1) or (314.2)'
        model.rules(2543) = {'(x(2)) | (x(4)) | (x(1)) | (x(3))'}; % '(26.1) or (314.1) or (8639.1) or (314.2)'
        model.rules(2750) = {'(x(2)) | (x(4)) | (x(1)) | (x(3))'}; % '(26.1) or (314.1) or (8639.1) or (314.2)'
        model.rules(2940) = {'(x(4)) | (x(60)) | (x(2)) | (x(61)) | (x(3))'}; % '(314.1) or (4128.1) or (26.1) or (4129.1) or (314.2)'
        model.rules(3133) = {'(x(2)) | (x(4)) | (x(1)) | (x(3))'}; % '(26.1) or (314.1) or (314.2)'
    end

    % assert if the generated names are the same
    assert(all(strcmp(model.rules, model2.rules)));

    fprintf('Succesfully completed model %s\n', modelsToTry{i});
end