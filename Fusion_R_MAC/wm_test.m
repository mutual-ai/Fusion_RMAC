% Code for the methods presented in our paper 
% M Wang et al, Fusion Global and local , ICLR2016.

% For oxford5k dataset 
%(mAP of our approach)
% mAP, without re-ranking = 0.7204
% mAP, after re-ranking = 0.7876
% mAP, after re-ranking and QE = 0.8105

% original approach 
% (G. Tolias, R. Sicre and H. Jegou, Particular object retrieval with
% integral max-pooling of CNN activations, ICLR2016.)
% mAP, without re-ranking = 0.6671
% mAP, after re-ranking = 0.7454
% mAP, after re-ranking and QE = 0.7733

run ../matconvnet-1.0-beta15/matlab/vl_setupnn.m
addpath('../yael_matlab_linux64_v438/');
mex aml.c; 													    % compile MEX for localization

data_folder = './datasets/'; % oxford5k/ and paris6k/ should be in here

% dataset_train				= 'oxford5k';    % dataset to learn the PCA-whitening on
% dataset_test 				= 'paris6k';     % dataset to evaluate on 

dataset_train				= 'paris6k';    % dataset to learn the PCA-whitening on
dataset_test 				= 'oxford5k';     % dataset to evaluate on 

% config files for Oxford and Paris datasets
gnd_test = load([data_folder, dataset_test, '/gnd_', dataset_test, '.mat']);    
gnd_train = load([data_folder, dataset_train, '/gnd_', dataset_train, '.mat']);

% image files are expected under each dataset's folder
im_folder_test = [data_folder, dataset_test, '/'];
im_folder_train = [data_folder, dataset_train, '/'];

% parameters of the method
use_rmac 				= 1;  	% use R-MAC, otherwise use MAC
rerank 					= 1000; 	% number of images to re-rank, no re-ranking if 0
L 						= 3;  	% number of levels in the region pyramid of R-MAC

step_box 				= 3;		% parameter t in the paper
qratio_t 				= 1.1;   % parameter s in the paper
rf_step 					= 3;		% fixed step for refinement
rf_iter 					= 5;		% number of iterations of refinement
nqe 						= 5;		% number of images to be used for QE

use_gpu	 				= 0;		% use GPU to get CNN responses

% choose pre-trained CNN model
%modelfn = 'imagenet-caffe-alex.mat'; ; lid = 15;				% use AlexNet
modelfn = 'imagenet-vgg-verydeep-16.mat'; 
lid = 31;		% use VGG


% the models used in our paper are downloaded
% current models on matconvnet site are slightly different
if exist(modelfn, 'file') ~= 2
	system(sprintf('wget http://cmp.felk.cvut.cz/~toliageo/ext/iclr16/%s', modelfn)); 
end

net = load(modelfn);
net.layers = {net.layers{1:lid}}; % remove fully connected layers
if use_gpu
	net = vl_simplenn_move(net, 'gpu') ;
end

im_fn_test = cellfun(@(x) [im_folder_test, x, '.jpg'], gnd_test.imlist, 'un', 0);
im_fn_train = cellfun(@(x) [im_folder_train, x, '.jpg'], gnd_train.imlist, 'un', 0);

% extract features
fprintf('Extracting features\n');
tic;
if ~use_rmac
	if rerank % additionally keep the 3D tensor of responses in case re-ranking is performed
		[vecs, conv3d] = cellfun(@(x) mac(imread(x), net), im_fn_test, 'un', 0);
		[vecs] = cellfun(@(x) vecpostproc(x), vecs, 'un', 0);
	else
		vecs = cellfun(@(x) vecpostproc(mac(imread(x), net)), im_fn_test, 'un', 0);
	end
	vecs_train = cellfun(@(x) vecpostproc(mac(imread(x), net)), im_fn_train, 'un', 0);
else
	if rerank % additionally keep the 3D tensor of responses in case re-ranking is performed
		[vecs, conv3d] = cellfun(@(x) rmac_regionvec(imread(x), net, L), im_fn_test, 'un', 0);
		[vecs] = cellfun(@(x) vecpostproc(x), vecs, 'un', 0);
	else
		vecs = cellfun(@(x) vecpostproc(rmac_regionvec(imread(x), net, L)), im_fn_test, 'un', 0);
	end
	vecs_train = cellfun(@(x) vecpostproc(rmac_regionvec(imread(x), net, L)), im_fn_train, 'un', 0);
end
toc;

% learn PCA
fprintf('Learning PCA-whitening\n');
[~, eigvec, eigval, Xm] = yael_pca (single(cell2mat(vecs_train')));

% apply PCA-whitening
fprintf('Applying PCA-whitening\n');
vecs = cellfun(@(x) vecpostproc(apply_whiten (x, Xm, eigvec, eigval)), vecs, 'un', 0);
if use_rmac
	% R-MAC: PCA-whitening is perform on region vectors, then they are aggregated
	vecs = cellfun(@(x) vecpostproc(sum(x, 2)), vecs, 'un', 0);
end

% process query images
fprintf('Process query images\n');
qimlist = {gnd_test.imlist{gnd_test.qidx}};
qim = arrayfun(@(x) crop_qim([im_folder_test, qimlist{x}, '.jpg'], gnd_test.gnd(x).bbx), 1:numel(gnd_test.qidx), 'un', 0);
if ~use_rmac
	qvecs = cellfun(@(x) vecpostproc(mac(x, net)), qim, 'un', 0);
else
	qvecs = cellfun(@(x) vecpostproc(rmac_regionvec(x, net, L)), qim, 'un', 0);
end
if rerank
	% MAC vector is used for localization
	if ~use_rmac
		qvecs_loc = qvecs;    
	else
		qvecs_loc = cellfun(@(x) vecpostproc(mac(x, net)), qim, 'un', 0);
	end
end
% apply PCA-whitening on query vectors
qvecs = cellfun(@(x) vecpostproc(apply_whiten (x, Xm, eigvec, eigval)), qvecs, 'un', 0);
if use_rmac
	qvecs = cellfun(@(x) vecpostproc(sum(x, 2)), qvecs, 'un', 0);
end

fprintf('Retrieval\n');

% final database vectors and query vectors
vecs = cell2mat(vecs');
qvecs_glo = vecs(:,gnd_test.qidx);
qvecs = cell2mat(qvecs);

% retrieval with inner product
% orignal version of Tolias
%[ranks,sim] = yael_nn(vecs, -qvecs, size(vecs, 2), 16);
% our version (using global as query)
[ranks,sim] = yael_nn(single(vecs), -single(qvecs_glo), size(vecs, 2), 16);
map = compute_map (ranks, gnd_test.gnd);
fprintf('mAP, without re-ranking = %.4f\n', map);

ranks_rerank = ranks;
ranks_rerank_qe = ranks;

if rerank
	for q = 1:numel(qim)

		qratio = size(qim{q}, 1) / size(qim{q}, 2);
		ids_toplist = ranks(1:rerank, q);
		% this version of the code does not support saving of compressed files
		% but CNN responses are quantized in the same way to reproduce the results of the paper		 
		conv3d_toplist = arrayfun(@(y)floor((15+((conv3d{y}>=128)*128+conv3d{y}.*(conv3d{y}<128)))/16), ids_toplist, 'un', 0); 

		% perform the localization      
	   bestbox = cellfun(@(x) aml(double(x), int32(10), double(qvecs_loc{q}), qratio, qratio_t, step_box, rf_step, rf_iter), conv3d_toplist, 'un', 0);

	   % get MAC or R-MAC from the localized windows
	   if use_rmac
		    vecs_bestbox = cellfun(@(x, b) vecpostproc(rmac_regionvec_act(x(b(2):b(3), b(4):b(5), :), L)), conv3d_toplist, bestbox, 'un', 0);
		    vecs_bestbox = cellfun(@(y) vecpostproc(sum(vecpostproc(apply_whiten(y, Xm, eigvec, eigval)), 2)), vecs_bestbox, 'un', 0);
	   else
			vecs_bestbox = cellfun(@(x, b) mac_act(x(b(2):b(3), b(4):b(5), :)), conv3d_toplist, bestbox, 'un', 0);
  			vecs_bestbox = cellfun(@(y) vecpostproc(apply_whiten(vecpostproc(y, 2), Xm, eigvec, eigval)), vecs_bestbox, 'un', 0);
	   end

	  % re-compute similarity and re-rank
      %original version
	  %scores_rerank = qvecs(:, q)'*cell2mat(vecs_bestbox');
      
      % our approach (using fused feature)
      cur_qvecs = [qvecs_glo(:,q) ; qvecs(:,q)];
      cur_qvecs = cur_qvecs / norm(cur_qvecs,2);
      
      cur_dbvecs_glo = vecs(:, ranks(1:rerank, q));
      cur_dbvecs_box = cell2mat(vecs_bestbox');
      cur_dbvecs     = [cur_dbvecs_glo ; cur_dbvecs_box]; 
      for k1 = 1:rerank
         cur_dbvecs(:,k1) = cur_dbvecs(:,k1) / norm(cur_dbvecs(:,k1),2);
      end
      
      scores_rerank = cur_qvecs' *cur_dbvecs;
	  [~, idx] = sort(scores_rerank, 'descend');
	  ranks_rerank(1:rerank, q) = ranks_rerank(idx, q);

	 % perform average query expansion
     % original version
     %scores_rerank_qe = mean([cell2mat({vecs_bestbox{idx(1:nqe)}}), qvecs(:, q)]')*cell2mat(vecs_bestbox');
     % our approach (using fused feature)
     scores_rerank_qe = mean([cur_dbvecs(:, idx(1:nqe)), cur_qvecs]')*cur_dbvecs;
     [~, idx] = sort(scores_rerank_qe, 'descend');
     ranks_rerank_qe(1:rerank, q) = ranks_rerank_qe(idx, q);
     disp(q);
	end
end

% mAP computation
map = compute_map (ranks_rerank, gnd_test.gnd);
fprintf('mAP, after re-ranking = %.4f\n', map);
map = compute_map (ranks_rerank_qe, gnd_test.gnd);
fprintf('mAP, after re-ranking and QE = %.4f\n', map);

% Paris6k
% mAP, without re-ranking = 0.7295
% mAP, after re-ranking = 0.7757
% mAP, after re-ranking and QE = 0.8059
 
% Extracting features
% Learning PCA-whitening
% Applying PCA-whitening
% Process query images
% Retrieval
% mAP, without re-ranking = 0.8302
% mAP, after re-ranking = 0.8515
% mAP, after re-ranking and QE = 0.8645

% Oxoford5k
% Elapsed time is 38998.392276 seconds.
% Learning PCA-whitening
% Applying PCA-whitening
% Process query images
% Retrieval
% mAP, without re-ranking = 0.6671
% mAP, after re-ranking = 0.7454
% mAP, after re-ranking and QE = 0.7733

% Extracting features
% Elapsed time is 40018.772401 seconds.
% Learning PCA-whitening
% Applying PCA-whitening
% Process query images
% save('./data_oxford/mac_mid_data/train_data.mat','vecs_train');
% Retrieval
% mAP, without re-ranking = 0.5501
% mAP, after re-ranking = 0.7057
% mAP, after re-ranking and QE = 0.7421