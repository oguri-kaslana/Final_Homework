function s = set_default_field(s, name, value)
%% =========================================================
% set_default_field
%
% 作用：
%   如果结构体 s 中没有字段 name，或者该字段为空，则设置默认值。
%% =========================================================

if ~isfield(s, name) || isempty(s.(name))
    s.(name) = value;
end

end
